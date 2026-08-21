# Production asynchronous benchmark

This is the production comparison for the final asynchronous workflow. It uses
the 2026-08-21 PBMC reruns and the KO result with the final one-inventory
grouped materializer. The local Piscem measurements are used only to calculate
speedup; they are not separate rows in these tables.

## Runtime

All times are wall-clock seconds.

| Dataset | Split and upload | Mean Lambda alignment | Post-split, before merge | Download and merge | Total | Speedup vs. baseline |
|---|---:|---:|---:|---:|---:|---:|
| PBMC 1K | 39.187 | 18.930 | 20.799 | 1.519 | 61.505 | 1.323x |
| PBMC 10K | 339.549 | 21.173 | 21.165 | 6.621 | 367.335 | 2.128x |
| KO, 13 samples | 1,206.075 | 31.556 | 13.063 | 186.625 | 1,405.763 | 6.187x |

`Mean Lambda alignment` is the mean per-invocation
`stream_and_piscem_seconds` recorded by the Lambda instrumentation: 18
invocations for PBMC 1K, 161 for PBMC 10K, and 917 for KO. It isolates streamed
input plus Piscem alignment rather than Lambda initialization and result
upload. It is not additive with the wall-time stages because Lambda alignment
overlaps continued splitting and upload.

The additive wall-time definition is:

```text
post_split_before_merge = total - split_and_upload - download_and_merge

total = split_and_upload + post_split_before_merge + download_and_merge
```

`Post-split, before merge` therefore includes the controller transition,
remaining Lambda readiness wait, ordered-manifest preparation, and other small
coordination costs. `Download and merge` is the measured parallel direct-S3 RAD
materializer time.

The KO total is the final reconstructed production path. It replaces the
original 288.948232-second per-sample-listing materialization with the tested
197.452990-second one-inventory grouped materialization. The final download and
merge column is the 186.624613 seconds spent in the sample materializers; the
remaining inventory and validation overhead falls in the post-split column.
The 13 regenerated KO RADs were byte-identical to the original outputs and all
passed `radtk` parsing.

## Cost

These are USD list-price costs for only the final async workflow. S3 and
ancillary services are excluded.

| Dataset | Async EC2 | Lambda | Async total |
|---|---:|---:|---:|
| PBMC 1K | $0.037176 | $0.060743 | $0.097920 |
| PBMC 10K | $0.222034 | $0.589648 | $0.811682 |
| KO, 13 samples | $0.849705 | $5.024941 | $5.874646 |

Costs use an on-demand Linux `m5dn.8xlarge` in `us-east-2` at $2.176/hour.
Lambda cost includes x86 compute at $0.0000166667/GB-second, requests at
$0.0000002/request, and additional ephemeral storage at
$0.0000000309/GB-second. The functions used 10,240 MB memory and 10,240 MB
ephemeral storage. Prices are before free tier, Savings Plans, credits, or
taxes.

The detailed formulas and reproducible calculators are in:

- [`scripts/calculate_pbmc_benchmark_costs.sh`](../scripts/calculate_pbmc_benchmark_costs.sh)
- [`scripts/calculate_ko_benchmark_costs.sh`](../scripts/calculate_ko_benchmark_costs.sh)
- [`docs/PBMC_BENCHMARK_COSTS_2026-08-21.md`](PBMC_BENCHMARK_COSTS_2026-08-21.md)
- [`docs/KO_BENCHMARK_COSTS_2026-08-21.md`](KO_BENCHMARK_COSTS_2026-08-21.md)

Price sources current on 2026-08-21:

- [Amazon EC2 `us-east-2` price catalog](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/20260821020257/us-east-2/index.csv)
- [AWS Lambda `us-east-2` price catalog](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSLambda/20260819224703/us-east-2/index.csv)
