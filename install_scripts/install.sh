#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
AWS_REGION_VALUE="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
AWS_CONFIGURE_INTERACTIVE="${AWS_CONFIGURE_INTERACTIVE:-auto}"

[[ "$AWS_CONFIGURE_INTERACTIVE" =~ ^(auto|0|1)$ ]] || {
    echo "AWS_CONFIGURE_INTERACTIVE must be auto, 0, or 1" >&2
    exit 1
}

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl unzip python3 python3-pip

case "$(uname -m)" in
    x86_64) awscli_arch=x86_64 ;;
    aarch64|arm64) awscli_arch=aarch64 ;;
    *) echo "Unsupported architecture for AWS CLI v2: $(uname -m)" >&2; exit 1 ;;
esac

awscli_tmp=$(mktemp -d)
trap 'rm -rf "$awscli_tmp"' EXIT
curl --fail --location --silent --show-error \
    "https://awscli.amazonaws.com/awscli-exe-linux-${awscli_arch}.zip" \
    --output "$awscli_tmp/awscliv2.zip"
unzip -q "$awscli_tmp/awscliv2.zip" -d "$awscli_tmp"
sudo "$awscli_tmp/aws/install" --update
rm -rf "$awscli_tmp"
trap - EXIT

aws --version
[[ "$(aws --version 2>&1)" == aws-cli/2.* ]] || {
    echo "AWS CLI v2 installation failed" >&2
    exit 1
}
aws configure set region "$AWS_REGION_VALUE"
aws configure set output json

# Prefer the EC2 instance profile: it supplies short-lived credentials without
# writing secrets to disk. For a manually launched host without a role, an
# interactive terminal falls back to the requested `aws configure` prompt.
if [[ "$AWS_CONFIGURE_INTERACTIVE" == "1" ]]; then
    aws configure
    caller_identity=$(aws sts get-caller-identity --region "$AWS_REGION_VALUE")
elif ! caller_identity=$(aws sts get-caller-identity --region "$AWS_REGION_VALUE" 2>/dev/null); then
    if [[ "$AWS_CONFIGURE_INTERACTIVE" == "auto" && -t 0 && -t 1 ]]; then
        echo "No EC2 role or environment credentials detected; starting AWS CLI v2 configuration."
        aws configure
        caller_identity=$(aws sts get-caller-identity --region "$AWS_REGION_VALUE")
    else
        echo "AWS CLI v2 is installed, but no credentials are available." >&2
        echo "Attach an EC2 instance profile or rerun with AWS_CONFIGURE_INTERACTIVE=1." >&2
        exit 1
    fi
fi
echo "AWS identity configured: $caller_identity"

bash "$REPO_ROOT/scripts/setup_instance_store_nvme.sh" \
    --yes --mount-point /mnt/nvme --owner "$(id -un):$(id -gn)" \
    --bind-container-storage --discard-container-cache
