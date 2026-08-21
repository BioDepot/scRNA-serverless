# KO benchmark EC2 and Lambda costs

## Bottom line

The KO baseline and async workflow used the same on-demand Linux
`m5dn.8xlarge` in `us-east-2`. The calculations include EC2 and Lambda and
exclude S3 and ancillary AWS services.

| Path | Baseline EC2 | Async EC2 | Lambda | Async total | Async / baseline cost |
|---|---:|---:|---:|---:|---:|
| Original measured async | $5.256848 | $0.905009 | $5.024941 | $5.929950 | 1.128x |
| Optimized materialization | $5.256848 | $0.849705 | $5.024941 | $5.874646 | 1.118x |

The optimized serverless workflow is **6.1867x faster** than the sequential
baseline and costs approximately **$0.6178 more**, or **11.75% more**, at list
price. The original measured workflow was 5.8086x faster and 12.80% more
expensive.

The optimized time is reconstructed, not a second complete Lambda execution:
the original 288.948232-second grouped materialization was replaced with the
independently measured 197.452990-second one-inventory implementation. The
Lambda work and its measured bill are unchanged.

## Rates and formulas

The rates and formulas are identical to the PBMC calculation:

```text
baseline_ec2 = baseline_seconds / 3600 * ec2_hourly_rate
async_ec2 = async_seconds / 3600 * ec2_hourly_rate

lambda_compute =
    billed_ms / 1000
    * memory_mb / 1024
    * lambda_compute_rate

lambda_requests = invocation_count * lambda_request_rate

lambda_ephemeral =
    billed_ms / 1000
    * max(ephemeral_mb - 512, 0) / 1024
    * lambda_ephemeral_rate

lambda_total = lambda_compute + lambda_requests + lambda_ephemeral
async_total = async_ec2 + lambda_total
```

Prices current on 2026-08-21:

- EC2 `m5dn.8xlarge`: $2.176/hour.
- Lambda x86 compute: $0.0000166667/GB-second.
- Lambda requests: $0.0000002/request.
- Lambda additional ephemeral storage: $0.0000000309/GB-second.

Sources:

- [Amazon EC2 `us-east-2` price catalog](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/20260821020257/us-east-2/index.csv)
- [AWS Lambda `us-east-2` price catalog](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSLambda/20260819224703/us-east-2/index.csv)

## Worked calculation

The retained evidence records:

- Baseline: 8,696.991876 seconds.
- Original async: 1,497.257900 seconds.
- Optimized reconstructed async: 1,405.762658 seconds.
- Lambda: 917 invocations and 30,095,476 billed milliseconds.
- Lambda configuration: 10,240 MB memory and 10,240 MB ephemeral storage.

```text
baseline_ec2 = 8696.991876 / 3600 * 2.176
             = $5.256848423

optimized_async_ec2 = 1405.762658 / 3600 * 2.176
                    = $0.849705429

lambda_compute = 30095.476 * 10 * 0.0000166667
               = $5.015922698

lambda_requests = 917 * 0.0000002
                = $0.000183400

lambda_ephemeral = 30095.476 * 9.5 * 0.0000000309
                 = $0.008834527

lambda_total = $5.024940625

optimized_async_total = 0.849705429 + 5.024940625
                      = $5.874646054
```

There are exactly 917 retained CloudWatch `REPORT` records for 917 expected
shards, so duplicate delivery did not add a billed invocation in this run.

The KO Lambda compute usage is 300,954.76 GB-seconds. An entirely unused
400,000 GB-second monthly Lambda free tier would cover its compute, and the
request count is also below the request allowance. The list-price comparison
does not assume those account-level allowances remain available.

## Reproduce the calculation

The calculator uses only retained local evidence, including the exported
CloudWatch reports:

```bash
bash scripts/calculate_ko_benchmark_costs.sh
```

To save another generated report:

```bash
OUTPUT_FILE=/mnt/nvme/benchmark-runs/ko-costs.md \
  bash scripts/calculate_ko_benchmark_costs.sh
```

Override rates or evidence roots with the environment variables documented by
`bash scripts/calculate_ko_benchmark_costs.sh --help`.
