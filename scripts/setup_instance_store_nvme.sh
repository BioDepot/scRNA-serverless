#!/usr/bin/env bash

# Build one XFS workspace from EC2 instance-store NVMe devices. This is
# intentionally destructive only for devices whose model is reported by EC2
# as "Amazon EC2 NVMe Instance Storage", unless explicit --device arguments
# are supplied. The EBS root device is never selected by automatic discovery.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: setup_instance_store_nvme.sh [options]

Options:
  --mount-point DIR          Workspace mount (default: /mnt/nvme).
  --owner USER:GROUP         Owner of the workspace (default: current user).
  --device DEVICE            Explicit scratch device; repeat for multiple
                             devices. Automatic EC2 instance-store discovery
                             is used when omitted.
  --raid-chunk-kib N         RAID 0 chunk size in KiB (default: 256).
  --bind-container-storage   Bind /var/lib/docker and /var/lib/containerd to
                             the instance-store workspace.
  --discard-container-cache Allow replacement of existing local container
                             cache when binding container storage.
  --yes                      Confirm that selected scratch devices may be
                             wiped and formatted. Required unless --dry-run.
  --dry-run                  Print the selected devices and planned actions.
  -h, --help                 Show this help.

If the mount point is already mounted, the script validates and reuses it
without wiping anything. Instance-store data is ephemeral; run this once on
each newly launched instance before writing pipeline data.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

shell_join() {
    local value quoted first=1
    for value in "$@"; do
        printf -v quoted '%q' "$value"
        if (( first == 1 )); then
            printf '%s' "$quoted"
            first=0
        else
            printf ' %s' "$quoted"
        fi
    done
    printf '\n'
}

MOUNT_POINT="/mnt/nvme"
OWNER_VALUE="$(id -un):$(id -gn)"
RAID_CHUNK_KIB=256
BIND_CONTAINER_STORAGE=0
DISCARD_CONTAINER_CACHE=0
CONFIRMED=0
DRY_RUN=0
EXPLICIT_DEVICES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mount-point)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            MOUNT_POINT="$2"; shift 2 ;;
        --owner)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            OWNER_VALUE="$2"; shift 2 ;;
        --device)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            EXPLICIT_DEVICES+=("$2"); shift 2 ;;
        --raid-chunk-kib)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            RAID_CHUNK_KIB="$2"; shift 2 ;;
        --bind-container-storage)
            BIND_CONTAINER_STORAGE=1; shift ;;
        --discard-container-cache)
            DISCARD_CONTAINER_CACHE=1; shift ;;
        --yes)
            CONFIRMED=1; shift ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            die "unknown argument: $1" ;;
    esac
done

[[ "$MOUNT_POINT" == /* ]] || die "--mount-point must be an absolute path"
[[ "$OWNER_VALUE" == *:* ]] || die "--owner must be USER:GROUP"
is_positive_integer "$RAID_CHUNK_KIB" || die "--raid-chunk-kib must be positive"
(( RAID_CHUNK_KIB % 4 == 0 )) || die "--raid-chunk-kib must be divisible by 4"
if (( DRY_RUN == 0 && CONFIRMED == 0 )); then
    die "device formatting requires --yes (or use --dry-run to inspect)"
fi

if (( EUID == 0 )); then
    ROOT_PREFIX=()
else
    command -v sudo >/dev/null 2>&1 || die "sudo is required when not running as root"
    ROOT_PREFIX=(sudo)
fi

run() {
    if (( DRY_RUN == 1 )); then
        printf '+ '
        shell_join "$@"
    else
        "$@"
    fi
}

run_root() {
    run "${ROOT_PREFIX[@]}" "$@"
}

is_ec2_instance_store_block() {
    local block_name="$1" parent_name model_file model
    while [[ -r "/sys/class/block/$block_name/partition" ]]; do
        parent_name=$(lsblk -ndo PKNAME "/dev/$block_name" 2>/dev/null || true)
        [[ -n "$parent_name" ]] || return 1
        block_name="$parent_name"
    done
    model_file="/sys/class/block/$block_name/device/model"
    [[ -r "$model_file" ]] || return 1
    model=$(tr -d '\000' < "$model_file")
    [[ "$model" == *"Amazon EC2 NVMe Instance Storage"* ]]
}

validate_mounted_workspace() {
    local source_device="$1" resolved_source block_name slave saw_slave=0
    [[ "$source_device" == /dev/* ]] || \
        die "$MOUNT_POINT source is not a block device: $source_device"
    resolved_source=$(readlink -f "$source_device")
    block_name=$(basename "$resolved_source")
    for slave in "/sys/class/block/$block_name/slaves/"*; do
        [[ -e "$slave" ]] || continue
        saw_slave=1
        is_ec2_instance_store_block "$(basename "$slave")" || \
            die "$MOUNT_POINT includes non-instance-store backing device: $(basename "$slave")"
    done
    if (( saw_slave == 0 )); then
        is_ec2_instance_store_block "$block_name" || \
            die "$MOUNT_POINT is not backed by EC2 instance-store NVMe: $source_device"
    fi
}

REUSED_MOUNT=0
if findmnt -rn -M "$MOUNT_POINT" >/dev/null 2>&1; then
    source_device=$(findmnt -rn -M "$MOUNT_POINT" -o SOURCE)
    filesystem=$(findmnt -rn -M "$MOUNT_POINT" -o FSTYPE)
    validate_mounted_workspace "$source_device"
    log "$MOUNT_POINT is already mounted from $source_device ($filesystem); reusing it"
    TARGET_DEVICE="$source_device"
    REUSED_MOUNT=1
fi

DEVICES=()
if (( REUSED_MOUNT == 1 )); then
    :
elif (( ${#EXPLICIT_DEVICES[@]} > 0 )); then
    DEVICES=("${EXPLICIT_DEVICES[@]}")
else
    for sys_device in /sys/block/nvme*n*; do
        [[ -d "$sys_device" ]] || continue
        device_name=$(basename "$sys_device")
        model=$(tr -d '\000' < "$sys_device/device/model" 2>/dev/null || true)
        if [[ "$model" == *"Amazon EC2 NVMe Instance Storage"* ]]; then
            DEVICES+=("/dev/$device_name")
        fi
    done
fi

if (( REUSED_MOUNT == 0 )); then
    (( ${#DEVICES[@]} > 0 )) || \
        die "no EC2 instance-store NVMe devices found; refusing to use the EBS root"

    mapfile -t DEVICES < <(printf '%s\n' "${DEVICES[@]}" | LC_ALL=C sort -u)
    for device in "${DEVICES[@]}"; do
        [[ "$device" == /dev/* ]] || die "invalid device path: $device"
        [[ -b "$device" ]] || die "not a block device: $device"
        if lsblk -nr -o MOUNTPOINT "$device" | awk 'NF {found=1} END {exit !found}'; then
            die "selected scratch device has a mounted filesystem: $device"
        fi
        if [[ -n "$(lsblk -nr -o PKNAME "$device" | awk 'NF {print; exit}')" ]]; then
            die "selected device is not a whole disk: $device"
        fi
        base=$(basename "$device")
        if find "/sys/class/block/$base/holders" -mindepth 1 -maxdepth 1 \
            -print -quit 2>/dev/null | grep -q .; then
            die "selected scratch device is already held by another block device: $device"
        fi
    done

    if (( ${#DEVICES[@]} >= 2 )) && [[ -e /dev/md0 ]]; then
        die "/dev/md0 already exists but is not mounted at $MOUNT_POINT"
    fi

    log "Selected ${#DEVICES[@]} scratch device(s): ${DEVICES[*]}"
    log "Plan: RAID0 when multiple devices exist, XFS, mount at $MOUNT_POINT"
    if (( DRY_RUN == 1 )); then
        log "Dry run: no device, filesystem, mount, or container state will change"
    fi

    if ! command -v mdadm >/dev/null 2>&1 || ! command -v mkfs.xfs >/dev/null 2>&1; then
        run_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mdadm xfsprogs
    fi

    for device in "${DEVICES[@]}"; do
        run_root wipefs -a "$device"
        base=$(basename "$device")
        if [[ -e "/sys/block/$base/queue/scheduler" ]]; then
            run_root sh -c 'printf "none\n" > "$1"' sh "/sys/block/$base/queue/scheduler"
        fi
    done

    if (( ${#DEVICES[@]} >= 2 )); then
        run_root mdadm --create /dev/md0 --level=0 \
            --raid-devices="${#DEVICES[@]}" --chunk="${RAID_CHUNK_KIB}K" \
            --metadata=1.2 --run "${DEVICES[@]}"
        run_root udevadm settle
        TARGET_DEVICE=/dev/md0
        run_root mkfs.xfs -f -d "su=${RAID_CHUNK_KIB}k,sw=${#DEVICES[@]}" "$TARGET_DEVICE"
    else
        TARGET_DEVICE="${DEVICES[0]}"
        run_root mkfs.xfs -f "$TARGET_DEVICE"
    fi

    run_root mkdir -p "$MOUNT_POINT"
    run_root mount -o noatime,nodiratime,logbufs=8,logbsize=256k,allocsize=64m \
        "$TARGET_DEVICE" "$MOUNT_POINT"
    run_root blockdev --setra 65536 "$TARGET_DEVICE"
fi

run_root chown "$OWNER_VALUE" "$MOUNT_POINT"

bind_container_directory() {
    local name="$1" source_directory="/var/lib/$1" target_directory="$MOUNT_POINT/$1"
    if mountpoint -q "$source_directory" 2>/dev/null; then
        log "$source_directory is already a mount point; leaving it unchanged"
        return 0
    fi
    if [[ -d "$source_directory" ]] && \
       [[ -n "$(find "$source_directory" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        (( DISCARD_CONTAINER_CACHE == 1 )) || \
            die "$source_directory is not empty; pass --discard-container-cache to replace this cache"
        run_root find "$source_directory" -mindepth 1 -delete
    fi
    run_root mkdir -p "$source_directory" "$target_directory"
    run_root mount --bind "$target_directory" "$source_directory"
    run_root mount --make-private "$source_directory"
    log "Bound $source_directory to ephemeral $target_directory"
}

if (( BIND_CONTAINER_STORAGE == 1 )); then
    for container_directory in /var/lib/docker /var/lib/containerd; do
        if ! mountpoint -q "$container_directory" 2>/dev/null && \
           [[ -d "$container_directory" ]] && \
           [[ -n "$(find "$container_directory" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] && \
           (( DISCARD_CONTAINER_CACHE == 0 )); then
            die "$container_directory is not empty; pass --discard-container-cache to replace this cache"
        fi
    done
    docker_was_active=0
    containerd_was_active=0
    systemctl is-active --quiet docker 2>/dev/null && docker_was_active=1
    systemctl is-active --quiet containerd 2>/dev/null && containerd_was_active=1
    run_root systemctl stop docker docker.socket containerd 2>/dev/null || true
    bind_container_directory docker
    bind_container_directory containerd
    if (( containerd_was_active == 1 )); then
        run_root systemctl start containerd
    fi
    if (( docker_was_active == 1 )); then
        run_root systemctl start docker
    fi
fi

log "Instance-store workspace ready: $(findmnt -rn -M "$MOUNT_POINT" -o SOURCE,FSTYPE,OPTIONS 2>/dev/null || echo "$TARGET_DEVICE")"
df -h "$MOUNT_POINT" || true
