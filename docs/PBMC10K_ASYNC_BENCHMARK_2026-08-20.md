# PBMC 10K asynchronous serverless benchmark

## Result

One development run compared the four PBMC 10K R1/R2 gzip files already on
NVMe. Input download and reusable AWS provisioning were excluded from both
measured data-path clocks.

| Workflow | Comparable wall time |
|---|---:|
| Local Piscem, 32 threads | 780.709533 s |
| Async serverless, first rapidgzip start through final RAD | 370.730382 s |

The serverless workflow saved 409.979151 seconds, for a **2.105869x speedup**
and a **52.5137% wall-time reduction** relative to local Piscem.

## Optimized path

- The two lanes remained separate; FASTQs were not concatenated.
- Four R1/R2 inputs ran with rapidgzip `-P8`, using all 32 driver vCPUs.
- Each lane was split at 4,000,000 read pairs (16,000,000 FASTQ lines),
  producing 81 L001 and 80 L002 shard pairs.
- Each manifest was published as soon as its R1/R2 shard pair reached S3, so
  Lambda mapping overlapped decompression and later uploads.
- Lambdas streamed S3 FASTQs into Piscem rather than staging complete inputs on
  Lambda storage.
- The final 161 RAD shards were read from S3 and materialized with 32 workers.

Split and upload took 338.045 seconds. After submission returned, the remaining
Lambda tail took 23.811321 seconds and parallel RAD materialization took
7.086415 seconds. The materializer wrote 10,645,901,309 bytes and reported
1,716.409 MiB/s of RAD payload throughput.

## Correctness

Both workflows processed 638,901,019 reads and mapped 369,342,136. Both final
RAD files passed `radtk view --rad-type single-cell --max-chunks 1`.

The local RAD was 10,645,897,517 bytes and the materialized RAD was
10,645,901,309 bytes. Byte identity is not expected: Piscem worker scheduling
can change record order and the number of 8-byte chunk headers. Full canonical
sorting of hundreds of millions of records was not included in this development
benchmark; both RADs are retained if that audit is needed later.

## Evidence and retained resources

Local evidence is under:

```text
/mnt/nvme/benchmark-runs/pbmc10k-20260820-dev1/
/mnt/nvme/runs/p10k-20260820-dev1/
```

AWS resources were retained:

- Lambda: `scrna-map-2026-08-20-16-58-22-409f901a`
- ECR: `scrna-serverless-2026-08-20-16-58-22-409f901a`
- IAM role: `scrna-lambda-role-2026-08-20-16-58-22-409f901a`
- FASTQ bucket: `scrna-fastq-171440768238-us-east-2-p10k-20260820-dev1`
- Manifest bucket: `scrna-txt-171440768238-us-east-2-p10k-20260820-dev1`
- MAP bucket: `scrna-map-171440768238-us-east-2-p10k-20260820-dev1`
- Quant/state bucket: `scrna-quant-171440768238-us-east-2-p10k-20260820-dev1`
- CloudWatch log group: `/aws/lambda/scrna-map-2026-08-20-16-58-22-409f901a`

The new function obtained 50 reserved concurrent executions because retained
development functions already held other reservations. This did not constrain
the run: shard arrival was decompression/upload paced, and completed Lambdas
remained close behind published manifests.

All destructive cleanup, S3 deletion, results cleanup, and CloudWatch deletion
gates were zero. No cleanup ran.
