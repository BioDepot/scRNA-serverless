# Paper update handoff: optimized serverless scRNA-seq workflow

## Status and scope

This document summarizes the implementation, validation, and development
benchmarks completed on 2026-08-20 and 2026-08-21. It is intended to support a
manuscript update. The performance results below are the completed, validated
three-trial measurements for both the local baseline and final asynchronous
workflow.

The benchmarked comparison excludes alevin-fry because that stage is identical
between the local and serverless arms. The local baseline is Piscem mapping on
an `m5dn.8xlarge` with 32 threads. The optimized serverless clock begins when
the first NVMe-resident FASTQ decompressor starts and ends when the final RAD
file, or all final sample RAD files for KO, has been materialized locally.

## Bottom line

The original serverless path was slower than a direct local Piscem invocation.
Four changes transformed it into a faster workflow:

1. Parallel FASTQ decompression with rapidgzip, with shards uploaded as soon as
   they are materialized.
2. Asynchronous Lambda execution so alignment overlaps continued splitting and
   upload.
3. Direct S3-to-FIFO streaming inside Lambda so Piscem begins before complete
   input objects have been staged to `/tmp`.
4. Parallel ranged-S3 RAD materialization, including sample-eager grouped
   materialization for the 13-sample KO workload.

The speedups computed from the three-trial arm means are 1.319x for PBMC 1K,
2.112x for PBMC 10K, and 6.639x for KO.

## Workflow changes

### 1. Static decompression and sharding policy

- Inputs begin as separate R1/R2 gzip files on the two-disk NVMe RAID0; lanes
  are not concatenated.
- The direct-pass cutoff is configurable through `DIRECT_GZIP_MAX_BYTES`.
  Small compressed pairs can be sent directly to Lambda. Larger pairs are
  decompressed, split, and uploaded.
- Shards contain four million read pairs, or 16 million FASTQ lines per mate.
- The decompressor policy is selected once at the beginning of a run:
  - when natural file-level parallelism consumes the available CPUs, each gzip
    stream receives one core and uses gzip;
  - when there are fewer streams than cores, CPUs are divided evenly and
    rapidgzip receives at most eight threads per stream;
  - rapidgzip is not used when only one core is assigned to a stream.
- A new R1/R2 pair is admitted when two cores have become available. R1 and R2
  release their cores independently; they do not have to finish as a pair.
- Larger split pairs are admitted before smaller ones. Direct-pass pairs do not
  consume decompression slots.
- Each completed shard pair is uploaded immediately, followed by its
  `input.txt` manifest, so Lambda alignment overlaps the remaining local work.

### 2. Asynchronous Lambda execution and idempotency

- PBMC runs use the S3/EventBridge manifest path. The uploader can finish and a
  separate controller can poll, wait, and materialize.
- The final KO benchmark directly invokes Lambda asynchronously after each
  manifest upload. This retains S3 as the data plane while making the
  controller the explicit work dispatcher.
- Duplicate delivery is handled with conditional S3 processing claims under
  `piscem_claims/<output-folder>.json`:
  - `PutObject` with `If-None-Match: *` elects one owner;
  - the owner records its request ID and conditionally renews a 180-second
    lease every 30 seconds using the claim ETag;
  - an expired claim can be taken over with `If-Match`;
  - a failed owner conditionally removes only the ETag it owns;
  - `output.txt`, written after all shard outputs, is the durable completion
    marker;
  - completed claims are retained as audit records.
- Five unit tests cover first-writer acquisition, live-owner rejection,
  expired-lease takeover, conditional failure release, and completed-event
  no-op behavior.

### 3. Streaming S3 inputs into Piscem in Lambda

- Lambda creates one FIFO per R1/R2 input and runs Piscem against the FIFO
  paths.
- Concurrent S3 `GetObject` readers write object bodies into the FIFOs while
  Piscem consumes them.
- Both uncompressed FASTQ shards and directly passed `.fastq.gz` inputs are
  supported. Piscem performs gzip decoding for direct gzip streams.
- The implementation verifies streamed byte counts and treats truncated input
  as a failure.
- Downloads no longer wait for all input files to be fully staged in Lambda
  ephemeral storage. The measured `stream_and_piscem_seconds` includes the
  streamed input and alignment interval.

### 4. Parallel RAD materialization

- `s3-rad-materialize` is a C++ AWS SDK client that inspects shard preludes,
  constructs one valid final prelude, and uses parallel ranged S3 reads to
  write shard payloads directly into their final output offsets.
- It replaces serial download-then-concatenate behavior and avoids staging all
  shard RADs independently on local storage.
- Readiness is defined by the expected-folder contract: both `map.rad` and the
  later `output.txt` marker must exist for every shard.
- PBMC produces one final RAD. KO uses an explicit sample manifest and produces
  one RAD per biological sample.
- KO readiness uses one global S3 inventory. Up to four complete samples are
  materialized concurrently with eight transfer threads each, for 32 aggregate
  workers. This removed repeated full-bucket listings from each sample worker.

## Generalized input and sample handling

- PBMC 1K and 10K use the same two-lane, four-stream policy and one logical
  sample.
- The KO manifest contains 130 R1/R2 pairs assigned to 13 samples:
  `A`, `B`, `C`, `D`, `E`, `F`, `G_1`, `G_2`, `H`, `I`, `J`, `L_1`, and `L_2`.
- Sample identity does not alter cell barcodes. It affects only the final
  materialization contract, yielding a separate RAD per sample and avoiding an
  artificial ordinal suffix in the barcode namespace.
- With the KO 7 GiB cutoff, 105 pairs pass through directly and 25 pairs are
  split, producing 917 Lambda invocations in total.

## Three-replicate production measurements

All cells are the arithmetic mean ± sample standard deviation in wall-clock
seconds across three trials. `Mean Lambda alignment` is first calculated over
all invocations within each trial, then summarized across trials. It overlaps
splitting/upload, so it is not additive with the wall stages.

| Dataset | Local baseline | Split/upload | Mean Lambda alignment | Post-split before merge | Download/merge | Async total | Speedup from arm means |
|---|---:|---:|---:|---:|---:|---:|---:|
| PBMC 1K | 80.753 ± 0.537 | 39.063 ± 0.120 | 19.663 ± 0.834 | 20.528 ± 0.969 | 1.613 ± 0.110 | 61.204 ± 0.955 | 1.319x |
| PBMC 10K | 780.502 ± 1.155 | 338.881 ± 3.780 | 21.463 ± 0.299 | 23.580 ± 2.400 | 7.067 ± 0.519 | 369.528 ± 3.469 | 2.112x |
| KO, 13 samples | 8,727.677 ± 27.409 | 1,215.728 ± 7.949 | 32.318 ± 0.252 | 7.509 ± 0.053 | 91.355 ± 1.184 | 1,314.592 ± 6.839 | 6.639x |

The additive async definition is:

```text
async_total = split_and_upload + post_split_before_merge + download_and_merge
speedup = local_baseline / async_total
```

The individual arm times are:

| Dataset | Arm | Trial 1 (s) | Trial 2 (s) | Trial 3 (s) | Mean (s) | SD (s) |
|---|---|---:|---:|---:|---:|---:|
| PBMC 1K | Local Piscem | 81.370129 | 80.492631 | 80.395011 | 80.752590 | 0.537027 |
| PBMC 1K | Final async | 61.505086 | 60.134026 | 61.972187 | 61.203766 | 0.955408 |
| PBMC 10K | Local Piscem | 781.662519 | 779.353604 | 780.488986 | 780.501703 | 1.154510 |
| PBMC 10K | Final async | 367.335378 | 373.526887 | 367.720768 | 369.527678 | 3.468773 |
| KO | Local Piscem | 8696.991876 | 8736.309241 | 8749.730907 | 8727.677341 | 27.408641 |
| KO | Final async | 1313.782067 | 1308.194146 | 1321.800187 | 1314.592133 | 6.839097 |

The replicate runner uses a fresh `m5dn.8xlarge` made from the minimal AMI, a
two-device NVMe RAID0, 32 local Piscem threads, the same four-million-read shard
contract, and cleanup gates disabled. Provisioning, dataset transfer, image
construction, and tool installation are outside measured regions.

An initial PBMC 1K trial-2 baseline that read the index cold from root EBS took
116.303968 seconds, including about 35.5 seconds of index loading. It was
excluded by the predeclared NVMe-resident baseline contract and replaced with
the 80.492631-second measurement after the unchanged index was copied to NVMe.
The independently timed async arm from that run remained valid.

## Correctness evidence

- PBMC local and serverless arms have identical total read and mapped-read
  counts. PBMC 1K has 66,601,887 reads and 40,832,376 mapped reads. PBMC 10K
  has 638,901,019 reads and 369,342,136 mapped reads.
- KO has 6,623,775,561 reads and 3,645,770,776 mapped reads in both arms.
  Equality was also checked independently for every sample.
- Every final RAD passed `radtk view --rad-type single-cell --max-chunks 1`.
- Piscem worker scheduling may alter record order, chunk boundaries, and the
  number of eight-byte chunk headers. PBMC canonicalization showed identical
  record multisets after sorting; the apparent eight-byte size discrepancy was
  a mistaken expected-size/header accounting assumption, not missing data.
- Re-materializing retained KO shards produced byte-identical RADs when the
  ordered shard manifest was unchanged.
- Alevin-fry output comparison normalizes barcode order before comparing count
  matrices, because parallel shard completion can change barcode ordering
  without changing counts.

## Lambda profile from retained KO trial 1

| Measurement | All | Direct gzip | Split FASTQ |
|---|---:|---:|---:|
| Invocations | 917 | 105 | 812 |
| Mean stream + Piscem | 32.055 s | 132.330 s | 19.088 s |
| Median stream + Piscem | 19.016 s | 80.777 s | 19.002 s |
| P95 stream + Piscem | 87.477 s | 339.196 s | 24.160 s |
| Mean Lambda total | 33.181 s | 137.222 s | 19.728 s |

The trial had 917 CloudWatch timing records, 917 reports, zero errors, zero
throttles, 46 cold starts, and peak concurrency of 46. Maximum observed memory
was 2,217 MB with 10,240 MB configured.

## Development cost estimates

The estimates use on-demand Linux `m5dn.8xlarge` pricing in `us-east-2` at
$2.176/hour and x86 Lambda pricing. S3 and ancillary services are excluded.

| Dataset | Local baseline EC2 | Async EC2 | Lambda | Async total |
|---|---:|---:|---:|---:|
| PBMC 1K | $0.049182 | $0.037176 | $0.060743 | $0.097920 |
| PBMC 10K | $0.472476 | $0.222034 | $0.589648 | $0.811682 |
| KO | $5.256848 | $0.794108 | $5.095134 | $5.889242 |

These are the previously reported trial-1 list-price development estimates,
before the free tier, Savings Plans, credits, or taxes. They have not been
silently relabeled as three-trial mean costs; the three-trial timing report is
the authoritative source for the updated runtime claims.

## Minimal AMI and reproducibility environment

- Private AMI: `ami-0aec4fdc8adb765ce` in `us-east-2`.
- Name: `scrna-seed-minimal-20260821-072456`.
- Root volume: 20 GiB gp3; snapshot `snap-02b81bdc5a7d6b66f`.
- The AMI contains the Piscem index and reference assets but no SSH private
  keys or AWS credential directories.
- Instance-store setup discovers only EC2 NVMe instance-store devices, creates
  RAID0 plus XFS, and never selects the EBS root automatically.
- AWS CLI v2 is installed/configured at runtime, and benchmark instances use an
  IAM instance profile rather than baked credentials.
- A clean boot, secret check, PBMC 1K Lambda run, materialization, and
  quantification completed with 5.2 GiB free on the 20 GiB root.
- The AMI is still private. Public release should follow the final clean-boot,
  secret, licensing, and three-replicate checks.

## Primary implementation and evidence files

- `scripts/e2e_serverless_pbmc.sh`: generalized driver/run workflow, CPU
  policy, async submission, timing, cleanup gates, and AMI runtime bootstrap.
- `scripts/split_upload_trigger_local.sh`: streaming split/upload/trigger path.
- `scrna-pipeline/map.py`: S3 claims, FIFO streaming, Piscem execution, and
  timing instrumentation.
- `scripts/async_lambda_control.sh`: async status/wait/materialization control.
- `tools/s3-rad-materializer/`: parallel ranged-S3 materializer.
- `scripts/materialize_sample_groups.sh`: global readiness inventory and
  sample-eager KO materialization.
- `scripts/benchmark_pbmc10k_async.sh`: one-shot PBMC baseline/async benchmark;
  now accepts `DATASET=pbmc1k` or `DATASET=pbmc10k`.
- `scripts/benchmark_ko_piscem_baseline.sh`: sequential 13-sample, 32-thread
  local KO baseline.
- `scripts/benchmark_ko_async.sh`: final KO async benchmark.
- `scripts/calculate_pbmc_benchmark_costs.sh` and
  `scripts/calculate_ko_benchmark_costs.sh`: reproducible cost formulas.
- `scripts/summarize_benchmark_replicates.py`: validates the additive stage
  accounting and produces per-trial and mean/sample-SD manuscript tables.
- `docs/three_replicate_benchmark_2026-08-21.tsv`: exact source measurements
  and original evidence paths for all nine paired trials.
- `docs/THREE_REPLICATE_BENCHMARK_2026-08-21.md`: generated per-trial,
  mean/sample-SD, median/range, and speedup report.
- `docs/PRODUCTION_BENCHMARK_2026-08-21.md`: retained trial-1 production table
  and cost calculation.
- `docs/KO_SAMPLE_EAGER_BENCHMARK_2026-08-21.md`: final KO optimization and
  Lambda profile.
- `docs/ASYNC_LAMBDA_RUNBOOK.md`: execution, idempotency, inspection, and
  recovery runbook.
- `docs/MINIMAL_AMI_AND_NVME.md`: AMI construction and NVMe setup.

A compact evidence copy is retained on persistent EBS at
`/home/ubuntu/benchmark-evidence/three-replicate-20260821`. It contains timing
markers, logs, manifests, Lambda configurations, all CloudWatch timing and
billing records, checksums, count comparisons, and RAD validation output. The
multi-gigabyte RAD payloads and `unmapped_bc_count.bin` files were intentionally
excluded from that compact copy; the original AWS benchmark resources and
CloudWatch logs were not cleaned up.

## Manuscript cautions and remaining work

1. Use the three-trial means and sample standard deviations for headline
   performance claims, while retaining the individual trials and ranges.
2. State the exact timed boundaries and that alevin-fry is excluded equally
   from both arms.
3. Report both driver EC2 time and Lambda compute; do not describe the faster
   workflow as necessarily cheaper for KO under current on-demand pricing.
4. Distinguish PBMC EventBridge triggering from the controller-invoked KO
   benchmark path.
5. Describe S3 claims as idempotency protection, not as a general distributed
   transaction system. S3 completion markers remain the readiness contract.
6. Confirm redistribution terms for the bundled reference assets before the
   AMI is made public.
7. Keep destructive AWS and S3 cleanup gated. The replicate evidence and
   CloudWatch profiles have been copied, but the retained cloud resources are
   still useful for development audit and follow-up profiling.
8. Update the AMI runtime setup to copy the baked Piscem index from root EBS to
   instance-store NVMe before timed local baselines, and point both PBMC and KO
   baseline scripts at that copy. The first cold-EBS setup attempt is excluded
   from the replicate analysis.
