# Cloud PBMC profiling and S3 RAD materializer benchmark

## Scope

This report records the 2026-08-20 measurements requested by
`CLOUD_PISCEM_PROFILE_HANDOFF.md` and the repeat benchmark of the concurrent
S3 RAD materializer. The repository was at commit
`b6d850641f3374875e836fe9ffb55bf76ee2f869` on branch
`feature/s3-rad-materializer`.

Large inputs and raw evidence remain on the instance-store NVMe. No FASTQ,
RAD, trace, or host-local configuration was added to Git.

## Host and storage

The handoff names `/storage`, but that path does not exist on this instance.
The measurements used `/mnt/nvme` after confirming that it is the intended
instance-store device.

| Property | Value |
|---|---|
| Instance | `m5dn.8xlarge` |
| CPU | Intel Xeon Platinum 8259CL, 16 cores / 32 logical CPUs |
| Memory | 124 GiB, no swap |
| Kernel | Linux 6.8.0-1044-aws, x86-64 |
| Storage | `/dev/md0`, RAID0 over two 558.8 GiB EC2 instance-store NVMe devices |
| RAID chunk | 512 KiB |
| Filesystem | XFS at `/mnt/nvme` |
| Capacity after benchmarks | 1.1 TiB total, 995 GiB available |

`sysstat`, `nvme-cli`, `jq`, and `aria2` were installed for diagnostics and
staging. The pinned AWS SDK for C++ 1.11.873 and
`s3-rad-materialize 0.1.0` were built; its unit test passed.

## Dataset cache

The repository-pinned 10x Genomics 3.0.0 PBMC archives and their extracted
FASTQs are retained on NVMe:

| Dataset | Archive | Archive bytes | Extracted FASTQs | Transfer observation | Extraction |
|---|---|---:|---|---:|---:|
| PBMC 1K | `/mnt/nvme/datasets/pbmc1k/pbmc_1k_v3_fastqs.tar` | 5,549,312,000 | `/mnt/nvme/datasets/pbmc1k/pbmc_1k_v3_fastqs/` | 16.33 s segmented resume after an interrupted 334 MiB single-stream prefix | 4.12 s |
| PBMC 10K | `/mnt/nvme/datasets/pbmc10k/pbmc_10k_v3_fastqs.tar` | 51,657,605,120 | `/mnt/nvme/datasets/pbmc10k/pbmc_10k_v3_fastqs/` | 4:00.50 segmented resume after an interrupted 366 MiB single-stream prefix | 37.58 s |

Each extracted dataset contains both lanes and all six expected `I1`, `R1`,
and `R2` gzip-compressed FASTQs. Source HTTP headers and exact file manifests
are stored beside each archive.

The PBMC 1K `p0` input was also reconstructed from the first 16,000,000 lines
of each lane-1 mate. It was byte-identical to the official retained S3 shard:

| Input | Bytes | SHA-256 |
|---|---:|---|
| R1 | 461,879,551 | `9da93c6f48264d1f80675f52397db9e951e9c0c36cc597d350491e9d26f4638c` |
| R2 | 965,879,551 | `47462b4c93d4c866daaaebf2f18b39197866b68aacc69ff0feccb982a1c5493f` |

## Single-shard Piscem profile

### S3 staging

The two official shard objects were downloaded separately with AWS CLI
multipart transfers using the `uw` profile in `us-east-2`.

| Input | Wall time | Effective throughput |
|---|---:|---:|
| R1 | 2.27 s | 194.0 MiB/s |
| R2 | 3.35 s | 275.0 MiB/s |
| Sequential total | 5.62 s | 242.3 MiB/s |

### Cache state

Only the four index data files were evicted before the primary run. `fincore`
reported:

| File | Size | Resident | Pages |
|---|---:|---:|---:|
| `.sshash` | 134.5 MiB | 0 B | 0 |
| `.ctab` | 30.1 MiB | 0 B | 0 |
| `.ectab` | 17.4 MiB | 0 B | 0 |
| `.refinfo` | 4.6 MiB | 0 B | 0 |

The same zero-resident check passed before the traced repeat.

### Timing

All runs used Piscem 0.10.3, `chromium_v3`, and six mapper threads.

| Run | Index load | Combined map/output | Process wall | User CPU | System CPU | Average CPU |
|---|---:|---:|---:|---:|---:|---:|
| Cold primary | 0.221 s | 13.801 s | 14.09 s | 84.10 s | 0.52 s | 600% |
| Warm index | 0.172 s | 13.790 s | 14.03 s | 84.02 s | 0.49 s | 602% |
| Cold traced | 0.236 s | 13.933 s | 14.38 s | 85.07 s | 2.85 s | 611% |

The cold index was 1.576% of active Piscem time. Warming it reduced index load
by only 49 ms and total process time by 60 ms. The primary run processed about
283,889 read pairs per wall-clock second.

`pidstat` sampled 605.9% average process CPU (618% peak) and zero process I/O
delay. During the primary run, `/dev/md0` averaged 15.9 MiB/s total throughput,
0.293 ms weighted await, and 0.446% utilization; peak utilization was 4.4%.
The initial targeted cold-index read peaked at about 170.0 MiB/s.

### Correctness and run-to-run chunk count

Every run produced the expected mapping counts and passed
`radtk view --rad-type single-cell --max-chunks 1`:

| Result | Value |
|---|---:|
| Read pairs | 4,000,000 |
| Mapped pairs | 2,438,983 |
| Percent mapped | 60.974575% |

The output size and chunk count varied together:

| Run | `map.rad` bytes | RAD chunks | Validation |
|---|---:|---:|---|
| Cold primary | 73,492,445 | 491 | Passed |
| Warm index | 73,492,437 | 490 | Passed |
| Cold traced | 73,492,445 | 491 | Passed |

This 8-byte difference is a worker-scheduling artifact, not a lost or added
read. Piscem maintains a buffer per mapper worker, writes two `uint32_t` chunk
header fields, and increments the global chunk count for every worker-local
flush. A different distribution of reads across six workers can therefore add
one 8-byte chunk header. Correctness checks should accept this run-to-run
variation while still requiring mapping counts and successful RAD parsing.

The conclusion was checked beyond counts and parseability. A binary framing
walk found contiguous, non-overlapping chunks ending exactly at EOF, no empty
chunks, 2,438,983 records in every file, and 70,103,608 record bytes after
excluding the per-chunk headers. The records were then canonicalized by sorting
alignments within each record and sorting the complete record multiset while
preserving duplicates. All three runs produced the same canonical SHA-256:

```text
2f735debb6738d5e8c93cf4c2ce96571e94914d512e7f512e9ff47d1fe560637
```

Their barcode-plus-UMI multisets also shared SHA-256
`eef243d2d182c1be77a9eef183f426ee985fe29700ab3d3f8d535b12ef9cd4f2`.
The files are therefore semantically identical; only alignment/record order
and worker-local chunk boundaries differ.

### RAD write blocking

The traced run measured:

| Output | Calls | Bytes issued | Cumulative syscall time |
|---|---:|---:|---:|
| `map.rad` | 8,974 | 73,492,453 | 0.196119 s |
| `unmapped_bc_count.bin` | 227 | 1,853,664 | 0.004247 s |

The `map.rad` issued-byte total is its 73,492,445-byte final size plus the
8-byte in-place chunk-count update. Its write syscalls occupied 1.364% of
traced wall time and did not force durability with `fsync`.

### Piscem conclusion

The observed bottleneck is FASTQ parsing, mapping, and/or RAD record
construction CPU. It is not S3 staging inside the Piscem timer, cold index
loading, or blocked NVMe output: all six mapper threads remained busy, index
caching saved only 60 ms, device wait/utilization stayed low, and RAD writes
blocked for only 196 ms in the traced diagnostic. A warm-cache thread sweep
followed by `perf record -g` is the next falsification experiment. If added
threads stop improving wall time while storage remains idle, profile or add
thread-local timers around record construction and the shared RAD output lock.

## S3 RAD materializer benchmark

The fixture contained 17 retained RAD shards, 1,231,688,321 aggregate S3
bytes, 1,174,144,868 combined payload bytes, 8,218 chunks, and a
1,177,529,777-byte final RAD.

### Baseline comparison

Three paired runs compared `aws s3 sync + radtk cat` with the ranged
materializer at 32 requested threads. The implementation caps workers at the
17-shard count.

| Metric | Median |
|---|---:|
| Baseline S3 sync | 4.069 s |
| Baseline `radtk cat` | 0.993 s |
| Baseline total | 5.062 s |
| Ranged materializer total | 1.415 s |
| Paired speedup | 3.535x |

The baseline sync delivered about 288.7 MiB/s. The ranged implementation's
thread-sweep median reached 989.2 MiB/s of payload, approximately 8.30 Gbit/s.
All three paired outputs passed `cmp`, shared SHA-256
`0317bac8c3d2420d74376f3520b0454408e8e723e39028e92342f0d52f7931f2`,
and the retained ranged output passed `radtk view`.

### Thread sweep

Each point is the median of three runs; every output was byte-identical to the
baseline.

| Requested threads | Actual maximum workers | Median inspect | Median transfer | Median total | Payload throughput |
|---:|---:|---:|---:|---:|---:|
| 1 | 1 | 0.997 s | 12.891 s | 13.906 s | 86.9 MiB/s |
| 2 | 2 | 0.558 s | 6.775 s | 7.346 s | 165.3 MiB/s |
| 4 | 4 | 0.328 s | 3.690 s | 4.042 s | 303.5 MiB/s |
| 8 | 8 | 0.229 s | 2.166 s | 2.406 s | 517.1 MiB/s |
| 16 | 16 | 0.185 s | 1.482 s | 1.684 s | 755.7 MiB/s |
| 32 | 17 | 0.153 s | 1.132 s | 1.302 s | 989.2 MiB/s |

Removing the former 1 Gbit/s ceiling exposed useful scaling through one worker
per shard. The maximum-worker result is 10.68x faster end-to-end than one
worker and 11.39x higher in payload throughput. The large 16-to-17-worker gain
also removes the tail where one of 16 workers must fetch a second shard.

## Evidence locations

| Evidence | Path |
|---|---|
| Piscem profile, inputs, outputs, monitors, and trace | `/mnt/nvme/benchmark-runs/piscem-cloud-profile.um6E5m/` |
| Materializer paired runs and retained comparison | `/mnt/nvme/benchmark-runs/s3-rad-materializer-benchmark/` |
| Materializer thread sweep | `/mnt/nvme/benchmark-runs/s3-rad-materializer-benchmark/thread-sweep.WB0wwJ/` |
| PBMC 1K dataset | `/mnt/nvme/datasets/pbmc1k/` |
| PBMC 10K dataset | `/mnt/nvme/datasets/pbmc10k/` |

The large data and outputs are intentionally retained pending review.
