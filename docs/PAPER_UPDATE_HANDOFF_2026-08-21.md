# Paper update handoff: optimized serverless scRNA-seq workflow

## Status and scope

This document summarizes the implementation, validation, and development
benchmarks completed on 2026-08-20 and 2026-08-21. It is intended to support a
manuscript update. The single-trial performance results below are the current
validated measurements, but performance claims should be updated from the
three-trial replicate analysis before they are used in the paper.

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

The current single-trial speedups are 1.323x for PBMC 1K, 2.128x for PBMC 10K,
and 6.620x for KO. These values are development results, not yet the final
three-replicate manuscript estimates.

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

## Current single-trial production measurements

All times are wall-clock seconds. `Mean Lambda alignment` is per-invocation and
overlaps splitting/upload, so it is not additive with the wall stages.

| Dataset | Local baseline | Split/upload | Mean Lambda alignment | Post-split before merge | Download/merge | Async total | Speedup |
|---|---:|---:|---:|---:|---:|---:|---:|
| PBMC 1K | 81.370 | 39.187 | 18.930 | 20.799 | 1.519 | 61.505 | 1.323x |
| PBMC 10K | 781.663 | 339.549 | 21.173 | 21.165 | 6.621 | 367.335 | 2.128x |
| KO, 13 samples | 8,696.992 | 1,215.181 | 32.055 | 7.565 | 91.036 | 1,313.782 | 6.620x |

The additive async definition is:

```text
async_total = split_and_upload + post_split_before_merge + download_and_merge
speedup = local_baseline / async_total
```

## Three-replicate benchmark in progress

Trial 1 uses the validated production measurements above. Two new local
baseline trials and two new final-async trials are being collected for every
dataset. Record the individual trials and report the arithmetic mean, standard
deviation, median, range, mean paired speedup, and speedup computed from the
arm means. Do not replace replicate distributions with only the fastest run.

| Dataset | Arm | Trial 1 (s) | Trial 2 (s) | Trial 3 (s) | Mean (s) | SD (s) |
|---|---|---:|---:|---:|---:|---:|
| PBMC 1K | Local Piscem | 81.370129 | pending | pending | pending | pending |
| PBMC 1K | Final async | 61.505086 | pending | pending | pending | pending |
| PBMC 10K | Local Piscem | 781.662519 | pending | pending | pending | pending |
| PBMC 10K | Final async | 367.335378 | pending | pending | pending | pending |
| KO | Local Piscem | 8696.991876 | pending | pending | pending | pending |
| KO | Final async | 1313.782067 | pending | pending | pending | pending |

The replicate runner uses a fresh `m5dn.8xlarge` made from the minimal AMI, a
two-device NVMe RAID0, 32 local Piscem threads, the same four-million-read shard
contract, and cleanup gates disabled. Provisioning, dataset transfer, image
construction, and tool installation are outside measured regions.

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

## Lambda profile from the final KO trial

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

These are list-price development estimates before the free tier, Savings
Plans, credits, taxes, and the three-replicate reruns.

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
- `docs/PRODUCTION_BENCHMARK_2026-08-21.md`: current production tables.
- `docs/KO_SAMPLE_EAGER_BENCHMARK_2026-08-21.md`: final KO optimization and
  Lambda profile.
- `docs/ASYNC_LAMBDA_RUNBOOK.md`: execution, idempotency, inspection, and
  recovery runbook.
- `docs/MINIMAL_AMI_AND_NVME.md`: AMI construction and NVMe setup.

## Manuscript cautions and remaining work

1. Replace the single-trial timing table with the three-trial results and
   variability statistics before making publication-level speed claims.
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
7. Keep destructive AWS and S3 cleanup gated until the replicate evidence and
   CloudWatch profiles have been copied and audited.
