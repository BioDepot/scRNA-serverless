#!/usr/bin/env bash

# Calculate EC2 and Lambda list-price costs for the retained KO baseline and
# final sample-eager asynchronous benchmark. S3 and ancillary AWS services are
# intentionally excluded.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: calculate_ko_benchmark_costs.sh

Defaults reproduce the retained 2026-08-20/21 KO calculation. Overrides:

  EC2_INSTANCE_TYPE             default: m5dn.8xlarge
  EC2_HOURLY_RATE               default: 2.176 USD/hour
  LAMBDA_COMPUTE_RATE           default: 0.0000166667 USD/GB-second
  LAMBDA_REQUEST_RATE           default: 0.0000002 USD/request
  LAMBDA_EPHEMERAL_RATE         default: 0.0000000309 USD/GB-second
  KO_BASELINE_DIR
  KO_ASYNC_DIR
  OUTPUT_FILE                   optional Markdown output path

The calculator uses the retained Lambda configuration and CloudWatch REPORT
export, so it does not require live AWS access. Prices are list prices before
free tier, Savings Plans, credits, or taxes.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_file() {
    [[ -f "$1" ]] || die "required file not found: $1"
}

result_value() {
    local key="$1" result_file="$2"
    awk -F= -v wanted="$key" \
        '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$result_file"
}

require_positive_number() {
    local name="$1" value="$2"
    awk -v value="$value" 'BEGIN {exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0)}' || \
        die "$name must be a positive number; got: $value"
}

calculate_costs() {
    local baseline_seconds="$1" async_seconds="$2" billed_ms="$3"
    local invocation_count="$4" memory_mb="$5" ephemeral_mb="$6"

    jq -n \
        --argjson baseline_seconds "$baseline_seconds" \
        --argjson async_seconds "$async_seconds" \
        --argjson billed_ms "$billed_ms" \
        --argjson invocation_count "$invocation_count" \
        --argjson memory_mb "$memory_mb" \
        --argjson ephemeral_mb "$ephemeral_mb" \
        --argjson ec2_rate "$EC2_HOURLY_RATE" \
        --argjson compute_rate "$LAMBDA_COMPUTE_RATE" \
        --argjson request_rate "$LAMBDA_REQUEST_RATE" \
        --argjson ephemeral_rate "$LAMBDA_EPHEMERAL_RATE" '
        {
          baseline_seconds: $baseline_seconds,
          async_seconds: $async_seconds,
          billed_ms: $billed_ms,
          invocation_count: $invocation_count,
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
    local final_json="$1"

    cat <<EOF
# KO benchmark EC2 and Lambda cost calculation

Rates are USD list prices in **us-east-2**, before free tier, Savings Plans,
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

| Path | Baseline seconds | Baseline EC2 | Async seconds | Async EC2 | Lambda | Async total | Async / baseline cost |
|---|---:|---:|---:|---:|---:|---:|---:|
EOF
    jq -r '
      "| Final sample-eager async | \(.baseline_seconds) | $\(.baseline_ec2_cost * 1000000 | round / 1000000) | \(.async_seconds) | $\(.async_ec2_cost * 1000000 | round / 1000000) | $\(.lambda_total_cost * 1000000 | round / 1000000) | $\(.async_total_cost * 1000000 | round / 1000000) | \(.async_to_baseline_cost_ratio * 1000 | round / 1000)x |"' \
        <<<"$final_json"

    cat <<EOF

## Lambda billing evidence

- Expected shards: **${expected_invocations}**
- Billed invocations: **${report_count}**
- Billed duration: **${billed_ms} ms**
- Memory: **${memory_mb} MB**
- Ephemeral storage: **${ephemeral_mb} MB**
- Lambda compute: **\$$(jq -r '.lambda_compute_cost' <<<"$final_json")**
- Lambda requests: **\$$(jq -r '.lambda_request_cost' <<<"$final_json")**
- Lambda additional ephemeral storage: **\$$(jq -r '.lambda_ephemeral_cost' <<<"$final_json")**
- Lambda total: **\$$(jq -r '.lambda_total_cost' <<<"$final_json")**

This is the directly measured 2026-08-21 Lambda-only rerun with four concurrent
sample materializers and a shared 32-thread budget. It is not reconstructed
from an earlier run.

An unused monthly Lambda free tier would reduce compute and request charges,
but this report does not assume that account-level allowance is available.
EOF
}

[[ ${1:-} == "-h" || ${1:-} == "--help" ]] && { usage; exit 0; }
[[ $# -eq 0 ]] || { usage >&2; exit 2; }

EC2_INSTANCE_TYPE="${EC2_INSTANCE_TYPE:-m5dn.8xlarge}"
EC2_HOURLY_RATE="${EC2_HOURLY_RATE:-2.176}"
LAMBDA_COMPUTE_RATE="${LAMBDA_COMPUTE_RATE:-0.0000166667}"
LAMBDA_REQUEST_RATE="${LAMBDA_REQUEST_RATE:-0.0000002}"
LAMBDA_EPHEMERAL_RATE="${LAMBDA_EPHEMERAL_RATE:-0.0000000309}"
KO_BASELINE_DIR="${KO_BASELINE_DIR:-/mnt/nvme/benchmark-runs/ko-piscem-baseline-20260820-dev1}"
KO_ASYNC_DIR="${KO_ASYNC_DIR:-/mnt/nvme/benchmark-runs/ko-async-sample-eager-20260821-dev1}"
OUTPUT_FILE="${OUTPUT_FILE:-}"

for command_name in jq sed awk; do
    command -v "$command_name" >/dev/null 2>&1 || die "$command_name not found"
done
for price_name in EC2_HOURLY_RATE LAMBDA_COMPUTE_RATE LAMBDA_REQUEST_RATE LAMBDA_EPHEMERAL_RATE; do
    require_positive_number "$price_name" "${!price_name}"
done

baseline_result="$KO_BASELINE_DIR/result.txt"
async_result="$KO_ASYNC_DIR/result.txt"
expected_file="$KO_ASYNC_DIR/expected_rad_folders.txt"
function_config="$KO_ASYNC_DIR/lambda-function-configuration.json"
report_events="$KO_ASYNC_DIR/cloudwatch-report-events.json"
for evidence_file in "$baseline_result" "$async_result" \
    "$expected_file" "$function_config" "$report_events"; do
    require_file "$evidence_file"
done

baseline_seconds=$(result_value wall_seconds "$baseline_result")
final_async_seconds=$(result_value first_decompressor_to_final_sample_rads_seconds "$async_result")
expected_invocations=$(awk 'NF {count++} END {print count + 0}' "$expected_file")
report_count=$(jq '[.events[] | select(.message | contains("REPORT RequestId:"))] | length' "$report_events")
billed_ms=$(jq -r '.events[].message' "$report_events" \
    | sed -nE 's/.*Billed Duration: ([0-9]+) ms.*/\1/p' \
    | awk '{sum += $1} END {printf "%.0f", sum}')
memory_mb=$(jq -r '.MemorySize' "$function_config")
ephemeral_mb=$(jq -r '.EphemeralStorage.Size' "$function_config")
architecture=$(jq -r '.Architectures[0]' "$function_config")

for numeric_pair in \
    "baseline_seconds:$baseline_seconds" \
    "final_async_seconds:$final_async_seconds" \
    "billed_ms:$billed_ms"; do
    require_positive_number "${numeric_pair%%:*}" "${numeric_pair#*:}"
done
[[ "$architecture" == "x86_64" ]] || die "retained KO function used unsupported architecture: $architecture"
(( report_count == expected_invocations )) || \
    die "retained KO evidence has $report_count REPORT records for $expected_invocations expected shards"

final_json=$(calculate_costs "$baseline_seconds" "$final_async_seconds" \
    "$billed_ms" "$report_count" "$memory_mb" "$ephemeral_mb")

if [[ -n "$OUTPUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    emit_report "$final_json" | tee "$OUTPUT_FILE"
else
    emit_report "$final_json"
fi
