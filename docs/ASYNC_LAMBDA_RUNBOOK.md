# Asynchronous Lambda execution runbook

This mode separates submission from completion. Shards are still uploaded from
NVMe in R1/R2 pairs, and each pair's `*_input.txt` manifest is published as soon
as both objects are durable in S3. EventBridge can therefore invoke that
shard's Lambda while later shards are still being split and uploaded. The
submission command exits after the last manifest is published; it does not wait
for mapping, download outputs, materialize the final RAD, or run alevin-fry.

The synchronous and asynchronous modes use the same immediate Lambda launch.
Their difference is where the driver waits:

- `synchronous` keeps running through all completion markers, RAD
  materialization, and quantification.
- `async-submit` records a durable run contract and exits after submission. A
  separate controller can inspect or join the run later.

## Safety defaults

Development cleanup remains gated. The defaults retain Lambda, IAM, ECR,
EventBridge, S3 objects, and CloudWatch logs:

```bash
export ALLOW_DESTRUCTIVE_CLEANUP=0
export ALLOW_S3_DELETE=0
export CLEANUP_AWS=0
export CLEANUP_RESULTS=0
export DELETE_CLOUDWATCH_LOGS=0
export SKIP_PREFLIGHT_CLEANUP=1
```

Do not enable either cleanup gate during benchmarking or development.

## Submit PBMC 1K from NVMe

Start with the four R1/R2 lane files already under the PBMC 1K directory. Index
reads are not used.

```bash
cd /home/ubuntu/scRNA-serverless

export RUN_ID=async-pbmc1k-$(date -u +%m%d-%H%M)
export AWS_REGION=us-east-2
export LOCAL_FASTQ_DIR=/mnt/nvme/datasets/pbmc1k/pbmc_1k_v3_fastqs
export EXECUTION_MODE=async-submit
export POLL_INTERVAL_SECONDS=1
export MATERIALIZER_THREADS=32

bash scripts/e2e_serverless_pbmc.sh pbmc1k --run
```

The uploader creates four rapidgzip processes on a 32-vCPU driver: R1 and R2
for each of two lanes, with eight threads per process. Every complete shard pair
is uploaded concurrently, followed immediately by its manifest. The last line
of the submit log prints the local state path, normally:

```text
/mnt/nvme/runs/<RUN_ID>/async_state.env
```

The state and expected-folder contract are also published under:

```text
s3://<OUTPUT_QUANT_BUCKET>/<RUN_ID>/async_state.env
s3://<OUTPUT_QUANT_BUCKET>/<RUN_ID>/expected_rad_folders.txt
```

## Check, wait, or materialize

Set the state path once:

```bash
STATE=/mnt/nvme/runs/<RUN_ID>/async_state.env
```

One status check:

```bash
bash scripts/async_lambda_control.sh --state "$STATE" status --verbose
```

`status` exits with status 0 only when every expected folder contains both
`map.rad` and the later `output.txt` completion marker. An incomplete run exits
with status 1, which makes it suitable for cron or an external supervisor.

Wait without materializing:

```bash
bash scripts/async_lambda_control.sh \
  --state "$STATE" wait \
  --poll-seconds 1 \
  --timeout-seconds 1800
```

Wait and materialize the final RAD directly from S3:

```bash
bash scripts/async_lambda_control.sh \
  --state "$STATE" materialize \
  --output /mnt/nvme/runs/<RUN_ID>/combined/map.rad \
  --threads 32 \
  --poll-seconds 1 \
  --timeout-seconds 1800
```

The controller and materializer do not delete or overwrite S3 objects. A local
output is also protected unless `--overwrite` is supplied.

## Idempotency and S3 claims

EventBridge and asynchronous Lambda delivery are at-least-once, so two
invocations may receive the same manifest. Each invocation first checks the
durable completion marker and then claims:

```text
s3://<OUTPUT_MAP_BUCKET>/piscem_claims/<output-folder>.json
```

The claim protocol is:

1. If `piscem_output/<folder>/output.txt` exists, return success without doing
   any work.
2. Create the claim with `PutObject` and `If-None-Match: *`. S3 accepts only one
   first writer. The JSON contains the Lambda request ID, manifest key, state,
   and lease expiration.
3. Renew the lease with `PutObject` and `If-Match: <current ETag>` while Piscem
   is running. The invocation also refreshes synchronously before publishing
   output.
4. A duplicate that sees a live lease raises `ClaimBusyError`. This makes the
   asynchronous delivery retry later; once the original writes `output.txt`,
   the retry becomes a successful no-op.
5. A lease that is no longer heartbeating can be taken over with an ETag-
   conditional write. If two recovery invocations race, only one succeeds.
6. A handled failure conditionally deletes only the claim ETag it owns, so the
   normal Lambda retry can start immediately. A timeout or process kill leaves
   a lease that becomes eligible for conditional takeover.
7. After `output.txt` is durable, the claim is retained as a completed audit
   record. The completion marker, not the claim state, is the final readiness
   contract.

Defaults are a 180-second lease and a 30-second heartbeat. They can be changed
when the Lambda is created:

```bash
export CLAIM_LEASE_SECONDS=180
export CLAIM_HEARTBEAT_SECONDS=30
export S3_CLAIM_PREFIX=piscem_claims
```

Keep the lease comfortably above a healthy shard's observed processing time.

## Diagnose an incomplete shard

List the incomplete folders:

```bash
bash scripts/async_lambda_control.sh --state "$STATE" status --verbose
```

Inspect claim ownership and completion objects without changing them:

```bash
aws s3 ls "s3://<OUTPUT_MAP_BUCKET>/piscem_claims/" --recursive --region us-east-2
aws s3 ls "s3://<OUTPUT_MAP_BUCKET>/piscem_output/" --recursive --region us-east-2
```

Inspect claim, timing, and failure messages:

```bash
aws logs tail "/aws/lambda/<LAMBDA_FUNCTION>" \
  --since 30m --format short --region us-east-2 \
  | grep -E 'CLAIM|PIPELINE_TIMING|Mapper failed|ERROR|REPORT'
```

Interpretation:

- `CLAIM busy` means another request ID still owns a live lease.
- `CLAIM takeover` means a stale owner was replaced atomically.
- `CLAIM released_after_failure` means a handled failure made the manifest
  immediately retryable.
- A claim with no heartbeat and no `output.txt` becomes recoverable after its
  lease expires.
- `output.txt` with `map.rad` means the shard is complete even if the final
  claim audit update was interrupted.

Do not delete a live claim to force progress. That removes the mutual exclusion
guarantee and can allow two Piscem writers to target the same output prefix.

## Final quantification

Materialization is necessarily a synchronization barrier: the final RAD header
and payload cannot be published until every expected shard is complete. After
the controller creates `combined/map.rad`, use the existing pipeline commands
for the non-RAD companion data and alevin-fry, or run the synchronous driver for
a one-command submission-to-quant workflow.

The asynchronous branch deliberately leaves submission and finalization
separate so an application, cron job, or queue consumer can own the policy for
when to join the run.
