# KO asynchronous serverless development benchmark

This is a one-run development benchmark, not a publication benchmark. The 130
R1/R2 pairs began on local NVMe. A static 7 GiB combined-pair cutoff sent 105
pairs to Lambda as gzip and split 25 pairs into 812 uncompressed shard pairs.
Each of the resulting 917 manifests was followed by a direct asynchronous
Lambda `Event` invocation. Alevin-fry was deliberately excluded from both arms.

## End-to-end result

| Measurement | Time |
|---|---:|
| Sequential local Piscem baseline, 32 threads per sample | 8,696.991876 s (2:24:56.992) |
| First gzip decompressor to final 13 sample RADs | 1,497.257900 s (24:57.258) |
| Time saved | 7,199.733976 s (1:59:59.734) |
| Speedup | 5.808613x |
| Wall-time reduction | 82.784187% |

The async upload stage took 1,206.074798 seconds from first decompressor start
to the last durable manifest/invocation, sustaining 1.223927 GB/s (9.791413
Gbit/s) across 1,476,147,122,083 FASTQ bytes. The last Lambda completion marker
arrived 16.817491 seconds after upload completion. Grouped materialization took
288.948232 seconds end to end; 182.634623 seconds of that was actual parallel
RAD materializer time and about 105.459 seconds was repeated per-sample S3
readiness inventory.

## Lambda profile

CloudWatch contains exactly 917 pipeline timing records and 917 Lambda REPORT
records. CloudWatch metrics show 917 invocations, zero errors, zero throttles,
and peak concurrency 46. The account's unreserved pool was sufficient.

| Input path | Invocations | Mean total | p50 | p95 | Maximum |
|---|---:|---:|---:|---:|---:|
| Direct gzip | 105 | 133.654 s | 77.182 s | 354.662 s | 494.308 s |
| Split uncompressed FASTQ | 812 | 19.670 s | 19.671 s | 23.160 s | 28.211 s |

Across all invocations, peak memory use was 2,217 MiB; the median was 981 MiB.
There were 46 cold starts, with mean initialization of 0.828 seconds. The
slowest direct-gzip invocation remained well under the 900-second function
timeout.

## Correctness and retained evidence

The 917 `map_info.json` files sum to 6,623,775,561 reads and 3,645,770,776
mapped reads, exactly matching the sequential local baseline. Read and mapped
counts also match the baseline independently for every one of the 13 samples,
which validates the sample manifest join. All 13 final RAD files pass a
`radtk view --max-chunks 1` parse check. Their combined size is
106,606,483,697 bytes. The 20,600-byte size difference from the local baseline
is consistent with a different shard/chunk-header layout, but this run did not
attempt a full canonical sort comparison at the 106.6 GB scale.

Evidence is retained under
`/mnt/nvme/benchmark-runs/ko-async-7gib-20260820-dev1`. The S3 inputs, Lambda
outputs, function, ECR image, IAM role, and CloudWatch logs were retained. No
cleanup ran.

## Grouped-materialization inventory optimization

On 2026-08-21, the grouped path was changed so one coordinator polls and saves
the complete S3 readiness inventory. All sample materializers reuse that local
immutable inventory rather than issuing their own `ListObjectsV2` scans.

The retained 917-shard KO output was materialized again into a separate NVMe
directory. The coordinator needed one logical paginated S3 inventory scan,
which took 5.092509 seconds. The 13 local subset validations took 4.850965
seconds in total, and the parallel materializers took 186.624613 seconds. Total
grouped materialization fell from 288.948232 to 197.452990 seconds: 91.495242
seconds saved, a 31.6649% reduction and 1.4634x materialization speedup.

All 13 regenerated RADs passed `radtk` parsing and are byte-for-byte identical
to the previous outputs. Holding the already-measured upload and Lambda stages
constant, the reconstructed end-to-end time is 1,405.762658 seconds
(23:25.763), or 6.1867x faster than the local Piscem baseline. This final
end-to-end figure is reconstructed rather than a second full pipeline run.

Optimization-test evidence is retained under
`/mnt/nvme/benchmark-runs/ko-grouped-single-inventory-20260821`.
