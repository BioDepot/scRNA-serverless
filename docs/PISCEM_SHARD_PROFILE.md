# Piscem single-shard NVMe profile

This profile checks whether loading the Piscem reference index is a material
part of one Lambda shard's mapping time. It uses one of the 17 PBMC 1K shards,
the same Piscem release and reference as the pipeline, six mapper threads, and
local files on `/storage`.

## Result

Index loading was not a bottleneck on this host. The primary, untraced run
loaded an explicitly uncached 186.6 MiB index in 0.136 seconds. The subsequent
mapping/output interval took 6.954 seconds, and total process wall time was
7.13 seconds.

| Measurement | Time | Interpretation |
|---|---:|---|
| Index load | 0.136 s | 1.9% of the Piscem start-to-finished-mapping interval |
| Mapping/output region | 6.954 s | 98.1%; includes FASTQ parsing, mapping, RAD record serialization, and RAD writes |
| Total process wall time | 7.13 s | GNU `time`, without syscall tracing |
| `map.rad` blocked write time | 0.0625 s | Cumulative write-syscall time in a separate traced run; included within mapping |
| Post-map `map.rad` finalization | <0.1 ms | Tail-buffer flush, chunk-count overwrite, and close in the traced run |

The primary Piscem log supplied the phase boundaries directly:

```text
[2026-08-19 19:29:00.030] [info] loading index from ...
[2026-08-19 19:29:00.166] [info] done loading index
[2026-08-19 19:29:07.120] [info] finished mapping.
```

The traced repeat took 7.26 seconds. It issued 73,492,445 bytes to `map.rad`
in 8,974 `write`/`writev` calls. This equals the 73,492,437-byte final file
plus Piscem's 8-byte in-place chunk-count update. Those syscalls accumulated
62.517 ms of blocked time, or 0.86% of traced wall time.

The run was CPU-heavy rather than index- or output-I/O-heavy: GNU `time`
reported 42.44 seconds of user CPU, 0.35 seconds of system CPU, 599% average
CPU utilization, and 251,328 KiB maximum resident memory. It processed
4,000,000 read pairs, mapped 2,438,983 (60.974575%), and produced 490 RAD
chunks. This is about 561,000 read pairs per wall-clock second on this host.
`radtk view --rad-type single-cell --max-chunks 1` parsed the result
successfully.

## What the phase names mean

Piscem does not have three serial phases called load, map, and write.

1. The main thread loads `.sshash`, `.ctab`, `.ectab`, and `.refinfo` before
   starting the parser and mapper workers.
2. Each mapper worker constructs RAD records in its own memory buffer while it
   maps reads.
3. After 5,000 records, the worker takes a shared output mutex and copies its
   buffer to the common `map.rad` stream. Other workers may continue mapping.
4. After all workers join, the main thread flushes the final stream buffer,
   seeks back to write the final chunk count, and closes the file.

Consequently, the log interval from `done loading index` to `finished mapping`
is a combined mapping/output interval. The 62.5 ms measurement isolates time
blocked in kernel output calls, but it does not isolate CPU time spent creating
and copying RAD records. It also is not additive to the 6.954-second interval.

The output is buffered through the Linux page cache and Piscem does not call
`fsync(2)`. The write measurement is therefore application-visible latency,
not time to force every byte to durable storage.

The relevant Piscem v0.10.3 implementation is in the pinned `piscem-cpp`
source: [reference index loading](https://github.com/COMBINE-lab/piscem-cpp/blob/2ae91fe4462a0d1c441926e81485dea57f5ccc41/include/reference_index.hpp#L28-L69),
[worker RAD buffering and writes](https://github.com/COMBINE-lab/piscem-cpp/blob/2ae91fe4462a0d1c441926e81485dea57f5ccc41/src/pesc_sc.cpp#L185-L399),
and [finalization](https://github.com/COMBINE-lab/piscem-cpp/blob/2ae91fe4462a0d1c441926e81485dea57f5ccc41/src/pesc_sc.cpp#L771-L829).

## Test fixture

The run was made on 2026-08-19 with Piscem 0.10.3 and `chromium_v3` geometry.

| Item | Value |
|---|---|
| R1 | `s3://scrna-fastq-171440768238-us-east-2-p1krg-0819-1054/pbmc1k/pbmc_1k_v3_S1_L001_R1_001_p0.fastq` |
| R1 bytes | 461,879,551 |
| R2 | `s3://scrna-fastq-171440768238-us-east-2-p1krg-0819-1054/pbmc1k/pbmc_1k_v3_S1_L001_R2_001_p0.fastq` |
| R2 bytes | 965,879,551 |
| Reference | [Zenodo record 19375096](https://zenodo.org/records/19375096/files/piscem_reference.tar.gz) |
| Loaded index bytes | 195,686,876 (186.6 MiB) |
| Storage | `/dev/nvme0n1p2`, ext4, mounted at `/storage` |
| CPU | Intel Core i9-13900KF; 32 logical CPUs available |
| Kernel | Linux 6.8.0-124-generic, x86-64 |

Network transfer time is excluded. The FASTQs remained resident after their
S3 download, matching the pipeline's download-then-map flow. Immediately before
each measured run, only the four index data files were evicted with targeted
`POSIX_FADV_DONTNEED` requests. `fincore` confirmed zero resident pages for all
four files. This avoids a disruptive system-wide `drop_caches` operation.

This local result identifies phase proportions; it is not a Lambda performance
benchmark. CPU model, storage, page-cache state, and Lambda memory/CPU allocation
must be matched before using the absolute times for capacity planning.

## Reproduce the primary run

Create a fresh run directory so an existing result is never overwritten:

```bash
set -euo pipefail

RUN=/storage/piscem-shard-profile-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$RUN"

curl -fL --retry 4 \
  -o "$RUN/piscem.tar.gz" \
  https://github.com/COMBINE-lab/piscem/releases/download/v0.10.3/piscem-x86_64-unknown-linux-gnu.tar.gz
curl -fL --retry 4 \
  -o "$RUN/piscem_reference.tar.gz" \
  https://zenodo.org/records/19375096/files/piscem_reference.tar.gz

tar -xzf "$RUN/piscem.tar.gz" -C "$RUN"
tar -xzf "$RUN/piscem_reference.tar.gz" -C "$RUN"

aws s3 cp --profile uw --region us-east-2 --no-progress \
  s3://scrna-fastq-171440768238-us-east-2-p1krg-0819-1054/pbmc1k/pbmc_1k_v3_S1_L001_R1_001_p0.fastq \
  "$RUN/pbmc_1k_v3_S1_L001_R1_001_p0.fastq"
aws s3 cp --profile uw --region us-east-2 --no-progress \
  s3://scrna-fastq-171440768238-us-east-2-p1krg-0819-1054/pbmc1k/pbmc_1k_v3_S1_L001_R2_001_p0.fastq \
  "$RUN/pbmc_1k_v3_S1_L001_R2_001_p0.fastq"
```

Evict only the reference data from the page cache and verify its state:

```bash
sync
find "$RUN/index_output_transcriptome" -maxdepth 1 -type f \
  -exec dd if={} iflag=nocache count=0 status=none \;

fincore -o RES,SIZE,PAGES,FILE \
  "$RUN/index_output_transcriptome/index_output_transcriptome.sshash" \
  "$RUN/index_output_transcriptome/index_output_transcriptome.ctab" \
  "$RUN/index_output_transcriptome/index_output_transcriptome.ectab" \
  "$RUN/index_output_transcriptome/index_output_transcriptome.refinfo"
```

All four `RES` and `PAGES` values should be zero. Run the same mapper command as
the Lambda, with six threads:

```bash
/usr/bin/time -v -o "$RUN/time.txt" \
  "$RUN/piscem-x86_64-unknown-linux-gnu/piscem" map-sc \
  -i "$RUN/index_output_transcriptome/index_output_transcriptome" \
  -g chromium_v3 \
  -1 "$RUN/pbmc_1k_v3_S1_L001_R1_001_p0.fastq" \
  -2 "$RUN/pbmc_1k_v3_S1_L001_R2_001_p0.fastq" \
  -t 6 \
  -o "$RUN/output" \
  2>&1 | tee "$RUN/piscem.log"
```

Use the timestamps on `loading index`, `done loading index`, and `finished
mapping` for the phase boundaries. Confirm the RAD output is structurally
readable:

```bash
radtk view \
  --rad-type single-cell \
  --max-chunks 1 \
  --input "$RUN/output/map.rad" \
  >/dev/null
```

## Optional RAD syscall diagnostic

`strace` adds measurement overhead, so use a separate repeat and do not treat
its wall time as the primary baseline:

```bash
strace -f -ttt -T -yy \
  -e trace=openat,close,write,writev,pwrite64,pwritev,pwritev2,lseek \
  -o "$RUN/rad-write.strace" \
  "$RUN/piscem-x86_64-unknown-linux-gnu/piscem" map-sc \
  -i "$RUN/index_output_transcriptome/index_output_transcriptome" \
  -g chromium_v3 \
  -1 "$RUN/pbmc_1k_v3_S1_L001_R1_001_p0.fastq" \
  -2 "$RUN/pbmc_1k_v3_S1_L001_R2_001_p0.fastq" \
  -t 6 \
  -o "$RUN/traced-output"
```

The trace uses `-yy` so every output descriptor is annotated with its path.
For `map.rad`, sum successful `write` and `writev` return values to account for
bytes and sum their trailing `<seconds>` values for cumulative blocked time.

## Next measurement

No index-loading optimization is justified by this local run. The next cloud
benchmark should repeat the cold-index method on the target instance or Lambda
configuration. If RAD generation still needs to be separated from mapping CPU,
add thread-local timers around `write_to_rad_stream` and the mutex-protected
`out_info.rad_file << rad_w` block in Piscem; the stock binary does not expose
those as independent phases.
