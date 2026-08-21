# Minimal seed AMI and instance-store NVMe

The production driver now requests a **20 GiB gp3 root volume** and keeps all
high-volume work on EC2 instance-store NVMe. The current public seed AMI has a
30 GiB root snapshot, so the driver automatically raises the request to 30 GiB
when that AMI is used. A newly built 20 GiB seed AMI launches at 20 GiB.

Twenty GiB is the smallest practical default for the current seed contents:

- the reference and piscem index occupy about 11.2 GiB;
- a clean Ubuntu 22.04 image and required system state occupy several GiB; and
- the builder requires at least 3 GiB free after cleanup.

The build no longer stages 11 GiB archive copies in `/tmp`. Both archives are
streamed over SSH directly into `/opt/scrna-seed`, so the build volume only
needs room for the extracted payload. `SEED_EBS_GB` remains tunable, but the
post-build free-space check fails before snapshot creation if it is too small.

## Build a private seed AMI

The command below creates billable EC2/EBS resources and terminates the builder
after the AMI is available. Failed builds also terminate the instance unless
`KEEP_INSTANCE_ON_EXIT=1` is set.

```bash
export AWS_REGION=us-east-2
export AWS_ACCOUNT_ID=123456789012
export KEY_NAME=my-builder-key
export KEY_PEM_PATH=/absolute/path/my-builder-key.pem
export SUBNET_ID=subnet-xxxxxxxx
export SECURITY_GROUP_ID=sg-xxxxxxxx
export INDEX_TAR=/absolute/path/index_output_transcriptome.tar.gz
export REFERENCE_TAR=/absolute/path/reference.tar.gz

SEED_EBS_GB=20 MIN_FREE_GB=3 \
  bash scripts/build_seed_ami.sh
```

The default is `MAKE_PUBLIC=0`. Publishing an AMI changes the account-level
AMI public-access setting and is therefore deliberately double-gated:

```bash
MAKE_PUBLIC=1 CONFIRM_PUBLIC_AMI=1 bash scripts/build_seed_ami.sh
```

After validation, set `DEFAULT_SEED_AMI_ID` in
`scripts/e2e_serverless_pbmc.sh` to the printed AMI ID. Until that change is
made, the existing 30 GiB public AMI remains the default and the driver's
snapshot-minimum check prevents an invalid 20 GiB launch request.

## Prepare the SSD/NVMe workspace

For a new runtime host, the combined installer installs AWS CLI v2, configures
the region and JSON output, verifies the caller identity, and then prepares
NVMe:

```bash
AWS_REGION=us-east-2 bash install_scripts/install.sh
```

An attached EC2 instance profile is preferred because it supplies rotating
credentials without storing secrets. If the host has no role and the installer
has an interactive terminal, it runs `aws configure`. Set
`AWS_CONFIGURE_INTERACTIVE=1` to require that prompt, or `0` to fail instead.
The configured principal must have the S3 permissions used by the pipeline,
including bucket creation.

Inspect the automatically selected devices first:

```bash
bash scripts/setup_instance_store_nvme.sh --dry-run
```

Then create the workspace:

```bash
bash scripts/setup_instance_store_nvme.sh \
  --yes \
  --mount-point /mnt/nvme \
  --owner "$(id -un):$(id -gn)" \
  --bind-container-storage \
  --discard-container-cache
```

Automatic discovery accepts only block devices whose EC2 model is
`Amazon EC2 NVMe Instance Storage`; it does not select the EBS root. The
`--yes` operation erases the selected instance-store devices, creates RAID 0
when two or more are present, formats XFS, and mounts it at `/mnt/nvme`.
Instance-store contents disappear when the EC2 instance is stopped or
terminated.

`--bind-container-storage` also places Docker and containerd state on the
ephemeral volume. This prevents image builds from filling the 20 GiB root.
Replacing an existing local container cache requires the separate
`--discard-container-cache` acknowledgement. Re-running the helper while the
workspace is mounted reuses it without formatting.

The end-to-end driver invokes this helper automatically and only falls back to
other EC2 types with local NVMe. It fails explicitly if no instance-store NVMe
is available instead of putting FASTQs and intermediate data on the small EBS
root.

### Runtime index placement follow-up

The seed AMI stores the 187 MiB Piscem index under `/opt/scrna-seed` on the
small EBS root so it survives instance creation. Before a timed local Piscem
baseline, runtime setup should copy that directory to instance-store NVMe and
set `INDEX_PREFIX` or `PISCEM_INDEX_PREFIX` to the NVMe copy. A cold load from
the baked EBS path added about 35.5 seconds to an otherwise comparable PBMC 1K
baseline during the three-replicate setup and that attempt was excluded.

Until this copy is automated in the AMI/runtime scripts, use:

```bash
mkdir -p /mnt/nvme/reference/index_output_transcriptome
rsync -a /opt/scrna-seed/index_output_transcriptome/ \
  /mnt/nvme/reference/index_output_transcriptome/
export INDEX_PREFIX=/mnt/nvme/reference/index_output_transcriptome/index_output_transcriptome
export PISCEM_INDEX_PREFIX="$INDEX_PREFIX"
```

The copy and any cache warming are environment preparation and must remain
outside the measured interval. The Lambda image build can continue to read the
baked seed from `/opt/scrna-seed`; this note concerns the local EC2 baseline.

## Clean an instance before snapshotting

`build_seed_ami.sh` streams the cleanup helper to the builder and runs it as its
final SSH command. To inspect or run it manually:

```bash
bash scripts/cleanup_instance_for_ami.sh --dry-run
sudo bash scripts/cleanup_instance_for_ami.sh --yes --min-free-gib 3
```

The confirmed command removes all standard per-user SSH and AWS credential
stores, EC2 SSH host keys, Git/GitHub credentials, histories, machine identity,
cloud-init state, logs, caches, and temporary files. It intentionally removes
the current instance's future SSH login path. Do not reconnect or run other
setup commands after cleanup; snapshot immediately. The AMI builder uses
`create-image --no-reboot` so the scrubbed cloud-init and SSH state is not
recreated before the snapshot is taken.
