# KO benchmark EC2 and Lambda cost calculation

Rates are USD list prices in **us-east-2**, before free tier, Savings Plans,
credits, or taxes. S3 and ancillary services are excluded.

## Formulas

`baseline_ec2 = baseline_seconds / 3600 * ec2_hourly_rate`

`async_ec2 = async_seconds / 3600 * ec2_hourly_rate`

`lambda_compute = billed_ms / 1000 * memory_mb / 1024 * compute_rate`

`lambda_requests = invocation_count * request_rate`

`lambda_ephemeral = billed_ms / 1000 * max(ephemeral_mb - 512, 0) / 1024 * ephemeral_rate`

`async_total = async_ec2 + lambda_compute + lambda_requests + lambda_ephemeral`

## Prices

- EC2 m5dn.8xlarge: **$2.176/hour**
- Lambda x86 compute: **$0.0000166667/GB-second**
- Lambda requests: **$0.0000002/request**
- Lambda additional ephemeral storage: **$0.0000000309/GB-second**

## Result

| Path | Baseline seconds | Baseline EC2 | Async seconds | Async EC2 | Lambda | Async total | Async / baseline cost |
|---|---:|---:|---:|---:|---:|---:|---:|
| Final sample-eager async | 8696.991876 | $5.256848 | 1313.782067 | $0.794108 | $5.095134 | $5.889242 | 1.12x |

## Lambda billing evidence

- Expected shards: **917**
- Billed invocations: **917**
- Billed duration: **30515896 ms**
- Memory: **10240 MB**
- Ephemeral storage: **10240 MB**
- Lambda compute: **$5.085992838632**
- Lambda requests: **$0.00018339999999999999**
- Lambda additional ephemeral storage: **$0.0089579412708**
- Lambda total: **$5.0951341799028**

This is the directly measured 2026-08-21 Lambda-only rerun with four concurrent
sample materializers and a shared 32-thread budget. It is not reconstructed
from an earlier run.

An unused monthly Lambda free tier would reduce compute and request charges,
but this report does not assume that account-level allowance is available.
