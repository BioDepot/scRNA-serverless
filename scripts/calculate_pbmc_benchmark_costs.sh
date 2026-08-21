#!/usr/bin/env bash

# Calculate EC2 and Lambda list-price costs for the retained PBMC 1K and 10K
# benchmark reruns. S3 and other ancillary AWS services are intentionally
# excluded. Lambda usage is read from the functions' retained CloudWatch REPORT
# records so retries or duplicate invocations are included if they occurred.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: calculate_pbmc_benchmark_costs.sh

The defaults reproduce the 2026-08-21 PBMC rerun cost calculation. Override
paths or prices with environment variables:

  AWS_REGION                    default: us-east-2
  EC2_INSTANCE_TYPE             default: m5dn.8xlarge
  EC2_HOURLY_RATE               default: 2.176 USD/hour
  LAMBDA_COMPUTE_RATE           default: 0.0000166667 USD/GB-second
  LAMBDA_REQUEST_RATE           default: 0.0000002 USD/request
  LAMBDA_EPHEMERAL_RATE         default: 0.0000000309 USD/GB-second
  PBMC1K_BENCHMARK_DIR
  PBMC10K_BENCHMARK_DIR
  PBMC1K_STATE_FILE
  PBMC10K_STATE_FILE
  OUTPUT_FILE                   optional Markdown output path

The script requires aws, jq, sed, and permission to read the retained Lambda
configurations and CloudWatch log groups. Prices are list prices before free
tier, Savings Plans, credits, or taxes.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
}

state_value() {
    local key="$1" state_file="$2"
    awk -F= -v wanted="$key" \
        '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$state_file"
}

require_positive_number() {
    local name="$1" value="$2"
    awk -v value="$value" 'BEGIN {exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0)}' || \
        die "$name must be a positive number; got: $value"
}

require_file() {
    [[ -f "$1" ]] || die "required file not found: $1"
}

calculate_dataset() {
    local dataset="$1" benchmark_dir="$2" state_file="$3"
    local baseline_file="$benchmark_dir/baseline-piscem-32t/wall-seconds.txt"
    local async_file expected_file function_name function_json logs_json
    local baseline_seconds async_seconds expected_invocations report_count billed_ms
    local memory_mb ephemeral_mb architecture attempt

    if [[ "$dataset" == "PBMC 1K" ]]; then
        async_file="$benchmark_dir/async-serverless/wall-seconds.txt"
    else
        async_file="$benchmark_dir/async-serverless/rapidgzip-to-final-rad-seconds.txt"
    fi
    expected_file="$benchmark_dir/async-serverless/expected_rad_folders.txt"

    require_file "$baseline_file"
    require_file "$async_file"
    require_file "$expected_file"
    require_file "$state_file"

    baseline_seconds=$(tr -d '[:space:]' < "$baseline_file")
    async_seconds=$(tr -d '[:space:]' < "$async_file")
    require_positive_number "${dataset} baseline seconds" "$baseline_seconds"
    require_positive_number "${dataset} async seconds" "$async_seconds"

    function_name=$(state_value LAMBDA_FUNCTION "$state_file")
    [[ -n "$function_name" ]] || die "LAMBDA_FUNCTION missing from $state_file"

    function_json=$(aws lambda get-function-configuration \
        --region "$AWS_REGION" \
        --function-name "$function_name" \
        --output json)
    memory_mb=$(jq -r '.MemorySize' <<<"$function_json")
    ephemeral_mb=$(jq -r '.EphemeralStorage.Size' <<<"$function_json")
    architecture=$(jq -r '.Architectures[0]' <<<"$function_json")
    [[ "$architecture" == "x86_64" ]] || \
        die "$function_name uses $architecture; provide the corresponding Lambda price"

    expected_invocations=$(awk 'NF {count++} END {print count + 0}' "$expected_file")
    # CloudWatch FilterLogEvents can occasionally return a partial event set
    # while streams are being indexed. Retry a short read if fewer reports than
    # the immutable expected-shard contract are returned.
    for attempt in 1 2 3; do
        logs_json=$(aws logs filter-log-events \
            --region "$AWS_REGION" \
            --log-group-name "/aws/lambda/$function_name" \
            --filter-pattern REPORT \
            --output json)
        report_count=$(jq '[.events[] | select(.message | contains("REPORT RequestId:"))] | length' \
            <<<"$logs_json")
        (( report_count >= expected_invocations )) && break
    done
    billed_ms=$(jq -r '.events[].message' <<<"$logs_json" \
        | sed -nE 's/.*Billed Duration: ([0-9]+) ms.*/\1/p' \
        | awk '{sum += $1} END {printf "%.0f", sum}')
    (( report_count > 0 )) || die "no Lambda REPORT records found for $function_name"
    [[ "$billed_ms" =~ ^[0-9]+$ ]] || die "could not sum Lambda billed duration for $function_name"
    if (( report_count != expected_invocations )); then
        warn "$dataset has $report_count billed invocations for $expected_invocations expected shards; all billed invocations are included"
    fi

    jq -n \
        --arg dataset "$dataset" \
        --arg function_name "$function_name" \
        --arg architecture "$architecture" \
        --argjson baseline_seconds "$baseline_seconds" \
        --argjson async_seconds "$async_seconds" \
        --argjson expected_invocations "$expected_invocations" \
        --argjson invocation_count "$report_count" \
        --argjson billed_ms "$billed_ms" \
        --argjson memory_mb "$memory_mb" \
        --argjson ephemeral_mb "$ephemeral_mb" \
        --argjson ec2_rate "$EC2_HOURLY_RATE" \
        --argjson compute_rate "$LAMBDA_COMPUTE_RATE" \
        --argjson request_rate "$LAMBDA_REQUEST_RATE" \
        --argjson ephemeral_rate "$LAMBDA_EPHEMERAL_RATE" '
        {
          dataset: $dataset,
          function_name: $function_name,
          architecture: $architecture,
          baseline_seconds: $baseline_seconds,
          async_seconds: $async_seconds,
          expected_invocations: $expected_invocations,
          invocation_count: $invocation_count,
          billed_ms: $billed_ms,
          memory_mb: $memory_mb,
          ephemeral_mb: $ephemeral_mb,
          baseline_ec2_cost: (($baseline_seconds / 3600) * $ec2_rate),
          async_ec2_cost: (($async_seconds / 3600) * $ec2_rate),
          lambda_compute_cost:
            (($billed_ms / 1000) * ($memory_mb / 1024) * $compute_rate),
          lambda_request_cost: ($invocation_count * $request_rate),
          lambda_ephemeral_cost:
            (($billed_ms / 1000) *
             ([($ephemeral_mb - 512), 0] | max) / 1024 * $ephemeral_rate)
        }
        | . + {
            lambda_total_cost:
              (.lambda_compute_cost + .lambda_request_cost + .lambda_ephemeral_cost)
          }
        | . + {
            async_total_cost: (.async_ec2_cost + .lambda_total_cost)
          }
        | . + {
            async_to_baseline_cost_ratio:
              (.async_total_cost / .baseline_ec2_cost)
          }'
}

emit_report() {
    local pbmc1_json="$1" pbmc10_json="$2" combined_json="$3"
    local session_seconds session_ec2_cost session_total_cost

    cat <<EOF
# PBMC benchmark EC2 and Lambda cost calculation

Rates are USD list prices in **${AWS_REGION}**, before free tier, Savings Plans,
credits, or taxes. S3 and ancillary services are excluded.

## Formulas

\`baseline_ec2 = baseline_seconds / 3600 * ec2_hourly_rate\`

\`async_ec2 = async_seconds / 3600 * ec2_hourly_rate\`

\`lambda_compute = billed_ms / 1000 * memory_mb / 1024 * compute_rate\`

\`lambda_requests = invocation_count * request_rate\`

\`lambda_ephemeral = billed_ms / 1000 * max(ephemeral_mb - 512, 0) / 1024 * ephemeral_rate\`

\`async_total = async_ec2 + lambda_compute + lambda_requests + lambda_ephemeral\`

## Prices

- EC2 ${EC2_INSTANCE_TYPE}: **\$${EC2_HOURLY_RATE}/hour**
- Lambda x86 compute: **\$${LAMBDA_COMPUTE_RATE}/GB-second**
- Lambda requests: **\$${LAMBDA_REQUEST_RATE}/request**
- Lambda additional ephemeral storage: **\$${LAMBDA_EPHEMERAL_RATE}/GB-second**

## Result

| Dataset | Baseline seconds | Baseline EC2 | Async seconds | Async EC2 | Lambda | Async total | Async / baseline cost |
|---|---:|---:|---:|---:|---:|---:|---:|
EOF

    jq -r '
      "| \(.dataset) | \(.baseline_seconds | @text) | $\(.baseline_ec2_cost * 1000000 | round / 1000000) | \(.async_seconds | @text) | $\(.async_ec2_cost * 1000000 | round / 1000000) | $\(.lambda_total_cost * 1000000 | round / 1000000) | $\(.async_total_cost * 1000000 | round / 1000000) | \(.async_to_baseline_cost_ratio * 1000 | round / 1000)x |"' \
        <<<"$pbmc1_json"
    jq -r '
      "| \(.dataset) | \(.baseline_seconds | @text) | $\(.baseline_ec2_cost * 1000000 | round / 1000000) | \(.async_seconds | @text) | $\(.async_ec2_cost * 1000000 | round / 1000000) | $\(.lambda_total_cost * 1000000 | round / 1000000) | $\(.async_total_cost * 1000000 | round / 1000000) | \(.async_to_baseline_cost_ratio * 1000 | round / 1000)x |"' \
        <<<"$pbmc10_json"
    jq -r '
      "| Combined | \(.baseline_seconds | @text) | $\(.baseline_ec2_cost * 1000000 | round / 1000000) | \(.async_seconds | @text) | $\(.async_ec2_cost * 1000000 | round / 1000000) | $\(.lambda_total_cost * 1000000 | round / 1000000) | $\(.async_total_cost * 1000000 | round / 1000000) | \(.async_to_baseline_cost_ratio * 1000 | round / 1000)x |"' \
        <<<"$combined_json"

    cat <<'EOF'

## Lambda billing evidence

| Dataset | Expected shards | Billed invocations | Billed duration | Memory | Ephemeral storage |
|---|---:|---:|---:|---:|---:|
EOF
    jq -r '
      "| \(.dataset) | \(.expected_invocations) | \(.invocation_count) | \(.billed_ms) ms | \(.memory_mb) MB | \(.ephemeral_mb) MB |"' \
        <<<"$pbmc1_json"
    jq -r '
      "| \(.dataset) | \(.expected_invocations) | \(.invocation_count) | \(.billed_ms) ms | \(.memory_mb) MB | \(.ephemeral_mb) MB |"' \
        <<<"$pbmc10_json"

    if [[ -f "$SESSION_START_NS_FILE" && -f "$SESSION_END_FILE" ]]; then
        session_seconds=$(awk -v start_ns="$(<"$SESSION_START_NS_FILE")" \
            -v end_epoch="$(stat -c %Y "$SESSION_END_FILE")" \
            'BEGIN {printf "%.6f", end_epoch - (start_ns / 1000000000)}')
        session_ec2_cost=$(awk -v seconds="$session_seconds" -v rate="$EC2_HOURLY_RATE" \
            'BEGIN {printf "%.9f", seconds / 3600 * rate}')
        session_total_cost=$(awk -v ec2="$session_ec2_cost" \
            -v lambda="$(jq -r '.lambda_total_cost' <<<"$combined_json")" \
            'BEGIN {printf "%.9f", ec2 + lambda}')
        cat <<EOF

## Full development-session allocation

From the first PBMC 1K baseline start through the final PBMC 10K validation:

- Elapsed EC2 allocation: **${session_seconds} seconds**
- EC2: **\$${session_ec2_cost}**
- Lambda: **\$$(jq -r '.lambda_total_cost' <<<"$combined_json")**
- Total: **\$${session_total_cost}**
EOF
    fi

    cat <<'EOF'

The Lambda list-price total includes every CloudWatch `REPORT` record found in
each fresh function's retained log group. An unused monthly Lambda free tier
would reduce compute and request charges, but this report does not assume that
account-level allowance is available.
EOF
}

[[ ${1:-} == "-h" || ${1:-} == "--help" ]] && { usage; exit 0; }
[[ $# -eq 0 ]] || { usage >&2; exit 2; }

AWS_REGION="${AWS_REGION:-us-east-2}"
EC2_INSTANCE_TYPE="${EC2_INSTANCE_TYPE:-m5dn.8xlarge}"
EC2_HOURLY_RATE="${EC2_HOURLY_RATE:-2.176}"
LAMBDA_COMPUTE_RATE="${LAMBDA_COMPUTE_RATE:-0.0000166667}"
LAMBDA_REQUEST_RATE="${LAMBDA_REQUEST_RATE:-0.0000002}"
LAMBDA_EPHEMERAL_RATE="${LAMBDA_EPHEMERAL_RATE:-0.0000000309}"

PBMC1K_BENCHMARK_DIR="${PBMC1K_BENCHMARK_DIR:-/mnt/nvme/benchmark-runs/pbmc1k-20260821-rerun1}"
PBMC10K_BENCHMARK_DIR="${PBMC10K_BENCHMARK_DIR:-/mnt/nvme/benchmark-runs/pbmc10k-20260821-rerun1}"
PBMC1K_STATE_FILE="${PBMC1K_STATE_FILE:-/mnt/nvme/runs/p1k-0821-rerun1/async_state.env}"
PBMC10K_STATE_FILE="${PBMC10K_STATE_FILE:-/mnt/nvme/runs/p10k-0821-rerun1/async_state.env}"
SESSION_START_NS_FILE="${SESSION_START_NS_FILE:-${PBMC1K_BENCHMARK_DIR}/baseline-piscem-32t/start.ns}"
SESSION_END_FILE="${SESSION_END_FILE:-${PBMC10K_BENCHMARK_DIR}/RESULTS.md}"
OUTPUT_FILE="${OUTPUT_FILE:-}"

for price_name in EC2_HOURLY_RATE LAMBDA_COMPUTE_RATE LAMBDA_REQUEST_RATE LAMBDA_EPHEMERAL_RATE; do
    require_positive_number "$price_name" "${!price_name}"
done
for command_name in aws jq sed awk; do
    command -v "$command_name" >/dev/null 2>&1 || die "$command_name not found"
done
aws sts get-caller-identity --region "$AWS_REGION" >/dev/null

pbmc1_json=$(calculate_dataset "PBMC 1K" "$PBMC1K_BENCHMARK_DIR" "$PBMC1K_STATE_FILE")
pbmc10_json=$(calculate_dataset "PBMC 10K" "$PBMC10K_BENCHMARK_DIR" "$PBMC10K_STATE_FILE")
combined_json=$(jq -n --argjson pbmc1 "$pbmc1_json" --argjson pbmc10 "$pbmc10_json" '
  [$pbmc1, $pbmc10]
  | {
    dataset: "Combined",
    baseline_seconds: (map(.baseline_seconds) | add),
    async_seconds: (map(.async_seconds) | add),
    baseline_ec2_cost: (map(.baseline_ec2_cost) | add),
    async_ec2_cost: (map(.async_ec2_cost) | add),
    lambda_total_cost: (map(.lambda_total_cost) | add),
    async_total_cost: (map(.async_total_cost) | add)
  }
  | . + {
      async_to_baseline_cost_ratio:
        (.async_total_cost / .baseline_ec2_cost)
    }')

if [[ -n "$OUTPUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    emit_report "$pbmc1_json" "$pbmc10_json" "$combined_json" | tee "$OUTPUT_FILE"
else
    emit_report "$pbmc1_json" "$pbmc10_json" "$combined_json"
fi
