# PBMC benchmark EC2 and Lambda costs

## Bottom line

The 2026-08-21 PBMC reruns used an on-demand Linux `m5dn.8xlarge` in
`us-east-2`. The server's local NVMe is included in the instance price. These
calculations include EC2 and Lambda and intentionally exclude S3, ECR,
CloudWatch, EventBridge, the existing boot EBS volume, taxes, and data
transfer.

| Dataset | Baseline EC2 | Async EC2 | Lambda | Async total | Async / baseline cost |
|---|---:|---:|---:|---:|---:|
| PBMC 1K | $0.049184 | $0.037176 | $0.060743 | $0.097920 | 1.991x |
| PBMC 10K | $0.472472 | $0.222034 | $0.589648 | $0.811682 | 1.718x |
| Combined | $0.521655 | $0.259210 | $0.650391 | $0.909601 | 1.744x |

The two timed baseline and async arms together cost approximately **$1.4313**.
Allocating the entire 1,789.615-second development session—from the first PBMC
1K baseline start through final PBMC 10K validation—gives **$1.0817 EC2 +
$0.6504 Lambda = $1.7321**.

These are list-price calculations before free tier, Savings Plans, credits, or
taxes. The two runs used only 38,952.62 Lambda GB-seconds and 179 requests. An
unused monthly Lambda free tier would therefore remove the compute and request
charges, but the calculation does not assume that account-level allowance is
still available.

## Rates used

- EC2 `m5dn.8xlarge`, on-demand Linux in Ohio: $2.176/hour.
- Lambda x86 tier-1 compute: $0.0000166667/GB-second.
- Lambda requests: $0.0000002/request.
- Lambda additional ephemeral storage: $0.0000000309/GB-second.

The rates came from the AWS regional price catalogs current on 2026-08-21:

- [Amazon EC2 `us-east-2` price catalog](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/20260821020257/us-east-2/index.csv)
- [AWS Lambda `us-east-2` price catalog](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSLambda/20260819224703/us-east-2/index.csv)

All four measured intervals exceed EC2's 60-second minimum, so the EC2 formula
can directly prorate the hourly rate by seconds.

## Formulas

For the local baseline:

```text
baseline_ec2 = baseline_seconds / 3600 * ec2_hourly_rate
```

For the asynchronous workflow:

```text
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

The functions used 10,240 MB memory and 10,240 MB ephemeral storage. Lambda
includes 512 MB ephemeral storage without an additional storage charge, so the
storage formula bills the remaining 9.5 GB.

## Inputs and worked calculations

### PBMC 1K

- Baseline wall time: 81.370129 seconds.
- Async wall time: 61.505086 seconds.
- Lambda: 18 invocations and 363,796 billed milliseconds.

```text
baseline_ec2 = 81.370129 / 3600 * 2.176
             = $0.049183722

async_ec2 = 61.505086 / 3600 * 2.176
          = $0.037176408

lambda_compute = 363.796 * 10 * 0.0000166667
               = $0.060632788

lambda_requests = 18 * 0.0000002
                = $0.000003600

lambda_ephemeral = 363.796 * 9.5 * 0.0000000309
                 = $0.000106792

async_total = 0.037176408 + 0.060632788 + 0.000003600 + 0.000106792
            = $0.097919588
```

### PBMC 10K

- Baseline wall time: 781.662519 seconds.
- Async wall time: 367.335378 seconds.
- Lambda: 161 invocations and 3,531,466 billed milliseconds.

```text
baseline_ec2 = 781.662519 / 3600 * 2.176
             = $0.472471567

async_ec2 = 367.335378 / 3600 * 2.176
          = $0.222033828

lambda_compute = 3531.466 * 10 * 0.0000166667
               = $0.588578844

lambda_requests = 161 * 0.0000002
                = $0.000032200

lambda_ephemeral = 3531.466 * 9.5 * 0.0000000309
                 = $0.001036662

async_total = 0.222033828 + 0.588578844 + 0.000032200 + 0.001036662
            = $0.811681534
```

Exactly one CloudWatch `REPORT` record was present per expected shard in both
runs, so there was no additional billed Lambda invocation from duplicate
delivery in these reruns.

## Reproduce the calculation

Run the checked-in calculator while the benchmark evidence and retained
CloudWatch logs are available:

```bash
bash scripts/calculate_pbmc_benchmark_costs.sh
```

To save an updated report:

```bash
OUTPUT_FILE=/mnt/nvme/benchmark-runs/pbmc-costs.md \
  bash scripts/calculate_pbmc_benchmark_costs.sh
```

All rates and evidence paths are environment-variable overrides documented by
`bash scripts/calculate_pbmc_benchmark_costs.sh --help`.
