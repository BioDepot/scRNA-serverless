#!/usr/bin/env bash

# Remove machine-specific identities, credentials, caches, and logs before an
# EC2 instance is snapshotted into an AMI. This intentionally removes the SSH
# access used for the current build; run it only as the final remote command.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: cleanup_instance_for_ami.sh [options]

Options:
  --yes                 Confirm removal of credentials and machine identity.
  --min-free-gib N      Require at least N GiB free on / afterward (default: 3).
  --dry-run             Print destructive commands without executing them.
  -h, --help            Show this help.

The cleanup removes every user's ~/.ssh and ~/.aws directory, EC2 SSH host
keys, Git/GitHub credential files, shell histories, cloud-init identity, apt
caches, temporary files, and logs. New SSH host keys and the selected EC2
launch key are generated/injected by cloud-init on the next instance boot.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
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

CONFIRMED=0
DRY_RUN=0
MIN_FREE_GIB=3

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            CONFIRMED=1; shift ;;
        --min-free-gib)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            MIN_FREE_GIB="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            die "unknown argument: $1" ;;
    esac
done

[[ "$MIN_FREE_GIB" =~ ^[1-9][0-9]*$ ]] || die "--min-free-gib must be a positive integer"
if (( DRY_RUN == 0 )); then
    (( EUID == 0 )) || die "run as root (for example: sudo $0 --yes)"
    (( CONFIRMED == 1 )) || die "credential and identity removal requires --yes"
fi

run() {
    if (( DRY_RUN == 1 )); then
        printf '+ '
        shell_join "$@"
    else
        "$@"
    fi
}

echo "Removing user credentials and SSH identities..."
USER_HOMES=(/root)
while IFS= read -r user_home; do
    USER_HOMES+=("$user_home")
done < <(find /home -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | LC_ALL=C sort)

for user_home in "${USER_HOMES[@]}"; do
    run rm -rf \
        "$user_home/.ssh" \
        "$user_home/.aws" \
        "$user_home/.config/gh" \
        "$user_home/.git-credentials" \
        "$user_home/.netrc"
    run find "$user_home" -maxdepth 2 -type f \
        \( -name '.bash_history' -o -name '.zsh_history' -o -name '.python_history' \) \
        -delete
done

run find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*' -delete
run mkdir -p /etc/cloud/cloud.cfg.d
if (( DRY_RUN == 1 )); then
    echo "+ write /etc/cloud/cloud.cfg.d/99-scrna-ami-security.cfg"
else
    printf '%s\n' \
        'ssh_deletekeys: true' \
        'ssh_genkeytypes: [rsa, ecdsa, ed25519]' \
        > /etc/cloud/cloud.cfg.d/99-scrna-ami-security.cfg
fi

echo "Removing transient package, log, and machine state..."
run apt-get clean
run rm -rf /var/lib/apt/lists
run mkdir -p /var/lib/apt/lists/partial
run journalctl --rotate || true
run journalctl --vacuum-size=1M || true
run find /tmp /var/tmp -mindepth 1 -delete
run cloud-init clean --logs --machine-id
run truncate -s 0 /etc/machine-id
run ln -sfn /etc/machine-id /var/lib/dbus/machine-id
run fstrim -av || true
run sync

if (( DRY_RUN == 1 )); then
    echo "Dry run complete; no files were changed."
    exit 0
fi

if find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*' -print -quit | grep -q .; then
    die "SSH host keys remain after cleanup"
fi
for user_home in "${USER_HOMES[@]}"; do
    [[ ! -e "$user_home/.ssh" ]] || die "SSH material remains: $user_home/.ssh"
    [[ ! -e "$user_home/.aws" ]] || die "AWS credential material remains: $user_home/.aws"
done

available_gib=$(df -BG --output=avail / | tail -n 1 | tr -dc '0-9')
used_gib=$(df -BG --output=used / | tail -n 1 | tr -dc '0-9')
echo "Final root usage: ${used_gib} GiB used, ${available_gib} GiB available"
(( available_gib >= MIN_FREE_GIB )) || \
    die "root volume has less than ${MIN_FREE_GIB} GiB free; increase the AMI build volume"

echo "AMI cleanup complete. Do not open another login session before snapshotting."
