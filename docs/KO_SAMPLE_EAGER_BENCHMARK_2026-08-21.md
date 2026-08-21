# KO sample-eager asynchronous benchmark

This records the final 2026-08-21 KO Lambda-only rerun. The retained local
Piscem result was used for correctness and speedup; Piscem baseline mapping was
not rerun. No Alevin step, S3 cleanup, Lambda deletion, or CloudWatch log
deletion ran.

## Change

The grouped materializer now has one global S3 readiness poller and a bounded
sample scheduler. A sample launches as soon as every shard in its contract has
both `map.rad` and `output.txt`. Ready samples are ordered largest first. Four
sample jobs run concurrently with eight transfer threads each, keeping the
aggregate budget at 32 threads. Each job receives an immutable snapshot of the
global listing, so it does not issue its own repeated S3 scan.

The PBMC workflows do not pass a sample manifest and therefore do not use this
grouped path.

## Retained-output test

A four-sample test used the retained KO S3 objects for A, B, G_1, and J. All
four jobs launched concurrently. The coordinator completed in 20.503288
seconds; the individual job times were 16.938106, 15.742600, 15.630646, and
20.095122 seconds. All four RADs were byte-identical to their previously
validated counterparts and passed `radtk`. The temporary RAD copies were then
removed, while timings and validation evidence were retained at:

`/mnt/nvme/benchmark-runs/ko-sample-eager-subset-test-20260821`

## Production rerun

| Measurement | Result |
|---|---:|
| Pairs | 130 |
| Direct gzip pairs | 105 |
| Split pairs | 25 |
| Lambda invocations | 917 |
| First decompressor to upload complete | 1,215.181179 s |
| Post-upload Lambda tail | 16.918832 s |
| All-Lambda readiness in grouped coordinator | 25.811516 s |
| Sample materializer summed work | 335.188445 s |
| First sample launch to final sample completion | 91.035595 s |
| Full grouped coordinator | 96.169761 s |
| First decompressor to all final RADs | 1,313.782067 s |
| Retained local baseline | 8,696.991876 s |
| Speedup versus baseline | 6.619813x |
| Wall-time reduction | 84.893834% |

The grouped coordinator made four global S3 listings and reached four active
sample jobs. It launched I, H, D, and L_1 on its first readiness snapshot,
when 914 of 917 shards were complete. The remaining sample transfers overlapped
the final three Lambda completions.

## Lambda profile

CloudWatch contains exactly 917 `PIPELINE_TIMING` records and 917 `REPORT`
records for this function.

| Measurement | All | Direct gzip | Split FASTQ |
|---|---:|---:|---:|
| Invocations | 917 | 105 | 812 |
| Mean stream + Piscem | 32.054538 s | 132.329890 s | 19.087898 s |
| Median stream + Piscem | 19.016216 s | 80.776669 s | 19.001587 s |
| P95 stream + Piscem | 87.477469 s | 339.195777 s | 24.160059 s |
| Mean Lambda total | 33.181432 s | 137.222461 s | 19.727851 s |

The 812 split inputs contain four million reads per full shard. Direct gzip
inputs bypass splitting and vary greatly in size, explaining their longer and
more variable invocation times. Billed duration was 30,515,896 ms. There were
46 cold starts; mean initialization was 807.362 ms. Maximum observed memory
was 2,217 MB in a function configured with 10,240 MB. CloudWatch metrics show
917 invocations, zero errors, zero throttles, and peak concurrency of 46.

## Correctness and retained resources

The 917 `map_info.json` files sum to 6,623,775,561 reads and 3,645,770,776
mapped reads. Every one of the 13 per-sample aggregates exactly matches the
retained local baseline, and every final RAD passes `radtk` parsing. Total
final RAD size is 106,606,483,753 bytes.

- Evidence: `/mnt/nvme/benchmark-runs/ko-async-sample-eager-20260821-dev1`
- Lambda: `scrna-ko-eager-20260821-dev1`
- FASTQ bucket: `scrna-ko-eager-fastq-171440768238-20260821-dev1`
- Manifest bucket: `scrna-ko-eager-txt-171440768238-20260821-dev1`
- Output bucket: `scrna-ko-eager-map-171440768238-20260821-dev1`
- Quant/evidence bucket: `scrna-ko-eager-quant-171440768238-20260821-dev1`
- CloudWatch log group: `/aws/lambda/scrna-ko-eager-20260821-dev1`

All resources and logs remain retained. The cost calculation is in
[`KO_BENCHMARK_COSTS_2026-08-21.md`](KO_BENCHMARK_COSTS_2026-08-21.md).
