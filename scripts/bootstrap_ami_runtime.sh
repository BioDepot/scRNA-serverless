#!/usr/bin/env bash

# Prepare a seed-AMI runtime from the current GitHub repository without
# rebuilding the AMI. The bootstrap resolves the requested ref to one exact
# commit before it downloads or runs the NVMe setup helper. The resolved commit
# and copied index location are recorded on instance-store NVMe.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bootstrap_ami_runtime.sh [options]

Options:
  --yes                       Confirm instance-store NVMe may be formatted.
  --dry-run                   Resolve GitHub ref and inspect the NVMe plan only.
  --repo OWNER/REPO           GitHub repository (default: BioDepot/scRNA-serverless).
  --ref REF                   Branch, tag, or commit (default: master).
  --mount-point DIR           Instance-store mount (default: /mnt/nvme).
  --checkout-dir DIR          Repository checkout (default: MOUNT/scRNA-serverless).
  --owner USER:GROUP          Runtime file owner (default: invoking user, or ubuntu).
  --no-bind-container-storage Do not bind Docker/containerd storage to NVMe.
  --discard-container-cache  Permit replacement of existing container caches.
  -h, --help                  Show this help.

Environment aliases:
  SCRNA_GITHUB_REPOSITORY, SCRNA_RUNTIME_REF, SCRNA_MOUNT_POINT,
  SCRNA_CHECKOUT_DIR, SCRNA_RUNTIME_OWNER, SCRNA_SEED_INDEX_DIR

The default mutable ref follows the repository's master branch. For a
reproducible benchmark, pass --ref with an immutable Git commit or release tag.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    default_owner_user="$SUDO_USER"
elif id ubuntu >/dev/null 2>&1; then
    default_owner_user=ubuntu
else
    default_owner_user=$(id -un)
fi
default_owner_group=$(id -gn "$default_owner_user")

GITHUB_REPOSITORY="${SCRNA_GITHUB_REPOSITORY:-BioDepot/scRNA-serverless}"
RUNTIME_REF="${SCRNA_RUNTIME_REF:-master}"
MOUNT_POINT="${SCRNA_MOUNT_POINT:-/mnt/nvme}"
CHECKOUT_DIR="${SCRNA_CHECKOUT_DIR:-}"
OWNER_VALUE="${SCRNA_RUNTIME_OWNER:-${default_owner_user}:${default_owner_group}}"
SEED_INDEX_DIR="${SCRNA_SEED_INDEX_DIR:-/opt/scrna-seed/index_output_transcriptome}"
BIND_CONTAINER_STORAGE=1
DISCARD_CONTAINER_CACHE=0
CONFIRMED=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            CONFIRMED=1; shift ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        --repo)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            GITHUB_REPOSITORY="$2"; shift 2 ;;
        --ref)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            RUNTIME_REF="$2"; shift 2 ;;
        --mount-point)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            MOUNT_POINT="$2"; shift 2 ;;
        --checkout-dir)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            CHECKOUT_DIR="$2"; shift 2 ;;
        --owner)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            OWNER_VALUE="$2"; shift 2 ;;
        --no-bind-container-storage)
            BIND_CONTAINER_STORAGE=0; shift ;;
        --discard-container-cache)
            DISCARD_CONTAINER_CACHE=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            die "unknown argument: $1" ;;
    esac
done

[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
    die "--repo must be an OWNER/REPO GitHub path"
[[ -n "$RUNTIME_REF" && "$RUNTIME_REF" != -* && "$RUNTIME_REF" != *..* ]] || \
    die "unsafe or empty Git ref: $RUNTIME_REF"
[[ "$MOUNT_POINT" == /* ]] || die "--mount-point must be absolute"
CHECKOUT_DIR="${CHECKOUT_DIR:-${MOUNT_POINT}/scRNA-serverless}"
[[ "$CHECKOUT_DIR" == "$MOUNT_POINT"/* ]] || \
    die "--checkout-dir must be below the instance-store mount point"
[[ "$OWNER_VALUE" == *:* ]] || die "--owner must be USER:GROUP"
[[ "$SEED_INDEX_DIR" == /* ]] || die "SCRNA_SEED_INDEX_DIR must be absolute"
owner_user=${OWNER_VALUE%%:*}
if (( EUID != 0 )) && [[ "$owner_user" != "$(id -un)" ]]; then
    die "non-root bootstrap must use the invoking user in --owner: $(id -un)"
fi
if (( DRY_RUN == 0 && CONFIRMED == 0 )); then
    die "instance-store setup requires --yes (or use --dry-run first)"
fi
if (( BIND_CONTAINER_STORAGE == 0 && DISCARD_CONTAINER_CACHE == 1 )); then
    die "--discard-container-cache requires container-storage binding"
fi

if (( EUID == 0 )); then
    ROOT_PREFIX=()
else
    command -v sudo >/dev/null 2>&1 || die "sudo is required when not running as root"
    ROOT_PREFIX=(sudo)
fi

missing_commands=()
for command_name in cmp curl git readlink rsync sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
done
if (( ${#missing_commands[@]} > 0 )); then
    (( DRY_RUN == 0 )) || \
        die "dry-run dependencies are missing: ${missing_commands[*]}"
    log "Installing bootstrap dependencies: ${missing_commands[*]}"
    "${ROOT_PREFIX[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    "${ROOT_PREFIX[@]}" env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq ca-certificates coreutils curl diffutils git rsync
fi

bootstrap_path=$(readlink -f "${BASH_SOURCE[0]}")
bootstrap_sha256=$(sha256sum "$bootstrap_path" | awk '{print $1}')

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
resolve_repo="$temp_dir/resolve"
repository_url="https://github.com/${GITHUB_REPOSITORY}.git"

git init -q "$resolve_repo"
git -C "$resolve_repo" remote add origin "$repository_url"
log "Resolving ${GITHUB_REPOSITORY}@${RUNTIME_REF}"
git -C "$resolve_repo" fetch -q --depth=1 origin "$RUNTIME_REF" || \
    die "could not fetch GitHub ref: $RUNTIME_REF"
resolved_commit=$(git -C "$resolve_repo" rev-parse 'FETCH_HEAD^{commit}')
[[ "$resolved_commit" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve a commit"
log "Resolved Git commit: $resolved_commit"

raw_base="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${resolved_commit}"
nvme_helper="$temp_dir/setup_instance_store_nvme.sh"
curl --fail --location --silent --show-error \
    "$raw_base/scripts/setup_instance_store_nvme.sh" --output "$nvme_helper"
[[ "$(head -n 1 "$nvme_helper")" == "#!/usr/bin/env bash" ]] || \
    die "downloaded NVMe helper is not the expected shell script"
nvme_helper_sha256=$(sha256sum "$nvme_helper" | awk '{print $1}')
log "Downloaded pinned NVMe helper: $nvme_helper_sha256"

nvme_args=(--mount-point "$MOUNT_POINT" --owner "$OWNER_VALUE")
if (( DRY_RUN == 1 )); then
    nvme_args+=(--dry-run)
else
    nvme_args+=(--yes)
fi
if (( BIND_CONTAINER_STORAGE == 1 )); then
    nvme_args+=(--bind-container-storage)
fi
if (( DISCARD_CONTAINER_CACHE == 1 )); then
    nvme_args+=(--discard-container-cache)
fi
bash "$nvme_helper" "${nvme_args[@]}"

destination_index_dir="$MOUNT_POINT/reference/index_output_transcriptome"
destination_index_prefix="$destination_index_dir/index_output_transcriptome"
runtime_env="$MOUNT_POINT/scrna-runtime.env"
runtime_record="$MOUNT_POINT/scrna-runtime-bootstrap.tsv"

if (( DRY_RUN == 1 )); then
    log "Dry run: no repository or index files were copied"
    log "Would check out $resolved_commit under $CHECKOUT_DIR"
    log "Would copy $SEED_INDEX_DIR to $destination_index_dir"
    exit 0
fi

[[ -d "$SEED_INDEX_DIR" ]] || die "seed index directory not found: $SEED_INDEX_DIR"
source_index_prefix="$SEED_INDEX_DIR/index_output_transcriptome"
for suffix in sshash ctab ectab refinfo; do
    [[ -f "${source_index_prefix}.${suffix}" ]] || \
        die "seed index component missing: ${source_index_prefix}.${suffix}"
done

if [[ -e "$CHECKOUT_DIR" && ! -d "$CHECKOUT_DIR/.git" ]]; then
    [[ -d "$CHECKOUT_DIR" ]] || die "checkout path is not a directory: $CHECKOUT_DIR"
    [[ -z "$(find "$CHECKOUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] || \
        die "checkout directory exists and is not an empty Git repository: $CHECKOUT_DIR"
fi
if [[ -d "$CHECKOUT_DIR/.git" ]]; then
    [[ -z "$(git -C "$CHECKOUT_DIR" status --porcelain --untracked-files=all)" ]] || \
        die "existing runtime checkout has local changes: $CHECKOUT_DIR"
    [[ "$(git -C "$CHECKOUT_DIR" remote get-url origin)" == "$repository_url" ]] || \
        die "existing runtime checkout has a different origin"
else
    mkdir -p "$CHECKOUT_DIR"
    git -C "$CHECKOUT_DIR" init -q
    git -C "$CHECKOUT_DIR" remote add origin "$repository_url"
fi
git -C "$CHECKOUT_DIR" fetch -q --depth=1 origin "$resolved_commit"
[[ "$(git -C "$CHECKOUT_DIR" rev-parse 'FETCH_HEAD^{commit}')" == "$resolved_commit" ]] || \
    die "runtime checkout resolved to an unexpected commit"
git -C "$CHECKOUT_DIR" checkout -q --detach FETCH_HEAD
cmp -s "$nvme_helper" "$CHECKOUT_DIR/scripts/setup_instance_store_nvme.sh" || \
    die "downloaded NVMe helper does not match the resolved checkout"
cmp -s "$bootstrap_path" "$CHECKOUT_DIR/scripts/bootstrap_ami_runtime.sh" || \
    die "bootstrap does not match the resolved checkout; download it from the same --ref"

mkdir -p "$destination_index_dir"
index_copy_start=$(date +%s.%N)
rsync -a "$SEED_INDEX_DIR/" "$destination_index_dir/"
index_copy_end=$(date +%s.%N)
for suffix in sshash ctab ectab refinfo; do
    cmp -s "${source_index_prefix}.${suffix}" "${destination_index_prefix}.${suffix}" || \
        die "copied index component failed verification: $suffix"
done

{
    printf 'export SCRNA_REPO_ROOT=%q\n' "$CHECKOUT_DIR"
    printf 'export SCRNA_RUNTIME_COMMIT=%q\n' "$resolved_commit"
    printf 'export INDEX_PREFIX=%q\n' "$destination_index_prefix"
    printf 'export PISCEM_INDEX_PREFIX=%q\n' "$destination_index_prefix"
} > "$runtime_env"

{
    printf 'field\tvalue\n'
    printf 'completed_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'github_repository\t%s\n' "$GITHUB_REPOSITORY"
    printf 'requested_ref\t%s\n' "$RUNTIME_REF"
    printf 'resolved_commit\t%s\n' "$resolved_commit"
    printf 'bootstrap_sha256\t%s\n' "$bootstrap_sha256"
    printf 'nvme_helper_sha256\t%s\n' "$nvme_helper_sha256"
    printf 'checkout_dir\t%s\n' "$CHECKOUT_DIR"
    printf 'seed_index_dir\t%s\n' "$SEED_INDEX_DIR"
    printf 'nvme_index_prefix\t%s\n' "$destination_index_prefix"
    printf 'index_copy_start_epoch\t%s\n' "$index_copy_start"
    printf 'index_copy_end_epoch\t%s\n' "$index_copy_end"
} > "$runtime_record"

"${ROOT_PREFIX[@]}" chown -R "$OWNER_VALUE" \
    "$CHECKOUT_DIR" "$destination_index_dir" "$runtime_env" "$runtime_record"

log "Runtime checkout ready: $CHECKOUT_DIR ($resolved_commit)"
log "NVMe index ready: $destination_index_prefix"
log "Load runtime variables with: source $runtime_env"
