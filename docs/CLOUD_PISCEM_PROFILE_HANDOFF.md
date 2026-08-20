# Cloud-agent handoff: profile one PBMC 1K Piscem shard

## Mission

Reproduce the six-thread Piscem experiment on the cloud host's `/storage`
NVMe, then determine whether elapsed time is dominated by:

- S3 staging;
- cold reference-index loading;
- FASTQ parsing and mapping CPU;
- RAD serialization and its shared output lock; or
- blocked reads or writes on the storage device.

Start with the exact `p0` shard used for the local control. It contains
4,000,000 read pairs in two uncompressed FASTQ files totaling 1,427,759,102
bytes (1.33 GiB). Do not start all 17 shards until this single-shard baseline
is correct and understood.

The local control and interpretation are documented in
[Piscem single-shard NVMe profile](PISCEM_SHARD_PROFILE.md). The local host was
not used to draw cloud performance conclusions.

## Fixed inputs

Use these exact artifacts so the result is comparable:

```text
Piscem: 0.10.3
Geometry: chromium_v3
Threads: 6
Region: us-east-2

R1: s3://scrna-fastq-171440768238-us-east-2-p1krg-0819-1054/pbmc1k/pbmc_1k_v3_S1_L001_R1_001_p0.fastq
R1 bytes: 461879551

R2: s3://scrna-fastq-171440768238-us-east-2-p1krg-0819-1054/pbmc1k/pbmc_1k_v3_S1_L001_R2_001_p0.fastq
R2 bytes: 965879551

Reference: https://zenodo.org/records/19375096/files/piscem_reference.tar.gz
Loaded index bytes: 195686876
```

Use branch `feature/s3-rad-materializer`. If the repository is already on the
instance:

```bash
git fetch origin
git switch feature/s3-rad-materializer
git pull --ff-only
```

Do not add FASTQs, RAD files, traces, or host-local configuration to Git.

## 1. Record the cloud environment

Create a new directory rather than reusing an old result:

```bash
set -euo pipefail

RUN=/storage/piscem-cloud-profile-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$RUN"

uname -a >"$RUN/uname.txt"
lscpu >"$RUN/lscpu.txt"
free -h >"$RUN/memory.txt"
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL >"$RUN/lsblk.txt"
findmnt -T /storage >"$RUN/storage-mount.txt"
df -h /storage >"$RUN/storage-space.txt"
nvme list >"$RUN/nvme-list.txt" 2>&1 || true
```

Confirm that `/storage` resolves to the intended local NVMe device. Stop if it
is actually the root EBS volume, network storage, or has less than 5 GiB free;
that would answer a different question.

Required commands are `aws`, `curl`, `tar`, `/usr/bin/time`, `fincore`,
`strace`, `iostat`, and `pidstat`. On Ubuntu, the corresponding packages not
already installed are generally `time`, `util-linux`, `strace`, and `sysstat`.
On Amazon Linux, install their `dnf` equivalents. Record any installation in
the agent's report, but do not alter the application image merely for this
experiment.

## 2. Establish AWS access

Use the `uw` profile when it exists; otherwise use the instance role:

```bash
AWS_REGION=us-east-2
AWS_ARGS=(--region "$AWS_REGION")

if aws configure list-profiles 2>/dev/null | grep -qx uw; then
  AWS_ARGS+=(--profile uw)
fi

aws "${AWS_ARGS[@]}" sts get-caller-identity
```

Record S3 metadata before downloading:

```bash
INPUT_BUCKET=scrna-fastq-171440768238-us-east-2-p1krg-0819-1054
R1_KEY=pbmc1k/pbmc_1k_v3_S1_L001_R1_001_p0.fastq
R2_KEY=pbmc1k/pbmc_1k_v3_S1_L001_R2_001_p0.fastq

aws "${AWS_ARGS[@]}" s3api head-object \
  --bucket "$INPUT_BUCKET" --key "$R1_KEY" \
  --query '{bytes:ContentLength,etag:ETag}' >"$RUN/r1-head.json"
aws "${AWS_ARGS[@]}" s3api head-object \
  --bucket "$INPUT_BUCKET" --key "$R2_KEY" \
  --query '{bytes:ContentLength,etag:ETag}' >"$RUN/r2-head.json"
```

## 3. Stage Piscem and the reference on NVMe

Keep the experiment self-contained instead of changing system binaries:

```bash
curl -fL --retry 4 \
  -o "$RUN/piscem.tar.gz" \
  https://github.com/COMBINE-lab/piscem/releases/download/v0.10.3/piscem-x86_64-unknown-linux-gnu.tar.gz
curl -fL --retry 4 \
  -o "$RUN/piscem_reference.tar.gz" \
  https://zenodo.org/records/19375096/files/piscem_reference.tar.gz
curl -fL --retry 4 \
  -o "$RUN/radtk.tar.xz" \
  https://github.com/COMBINE-lab/radtk/releases/download/v0.1.0/radtk-x86_64-unknown-linux-gnu.tar.xz

tar -xzf "$RUN/piscem.tar.gz" -C "$RUN"
tar -xzf "$RUN/piscem_reference.tar.gz" -C "$RUN"
tar -xJf "$RUN/radtk.tar.xz" -C "$RUN"

PISCEM="$RUN/piscem-x86_64-unknown-linux-gnu/piscem"
RADTK="$RUN/radtk-x86_64-unknown-linux-gnu/radtk"
INDEX_DIR="$RUN/index_output_transcriptome"
INDEX_PREFIX="$INDEX_DIR/index_output_transcriptome"

"$PISCEM" --version
"$RADTK" --version
find "$INDEX_DIR" -maxdepth 1 -type f -printf '%f %s\n' \
  | sort >"$RUN/index-files.txt"
```

Expected index data files are:

| File | Bytes |
|---|---:|
| `.sshash` | 141,071,270 |
| `.ctab` | 31,574,218 |
| `.ectab` | 18,262,788 |
| `.refinfo` | 4,778,600 |

## 4. Download the PBMC shard and time S3 separately

Run two separate `aws s3 cp` commands. They are deliberately outside the
Piscem timer. Each `cp` can still use the AWS CLI's multipart transfer
concurrency, but R1 and R2 are staged as distinct operations.

```bash
R1="$RUN/pbmc_1k_v3_S1_L001_R1_001_p0.fastq"
R2="$RUN/pbmc_1k_v3_S1_L001_R2_001_p0.fastq"

/usr/bin/time -v -o "$RUN/r1-download.time" \
  aws "${AWS_ARGS[@]}" s3 cp --no-progress \
  "s3://$INPUT_BUCKET/$R1_KEY" "$R1"

/usr/bin/time -v -o "$RUN/r2-download.time" \
  aws "${AWS_ARGS[@]}" s3 cp --no-progress \
  "s3://$INPUT_BUCKET/$R2_KEY" "$R2"

test "$(stat -c %s "$R1")" -eq 461879551
test "$(stat -c %s "$R2")" -eq 965879551
stat -c '%n %s bytes' "$R1" "$R2" >"$RUN/fastq-files.txt"
```

Keep these download times separate in the final report. The new files will
normally be resident in the page cache, which matches the Lambda's
download-then-map behavior.

## 5. Run the primary cold-index, six-thread profile

Evict only the index files. Do not run a system-wide `drop_caches`, because it
would disturb other work on the instance.

```bash
sync
find "$INDEX_DIR" -maxdepth 1 -type f \
  -exec dd if={} iflag=nocache count=0 status=none \;

fincore -o RES,SIZE,PAGES,FILE \
  "$INDEX_PREFIX.sshash" \
  "$INDEX_PREFIX.ctab" \
  "$INDEX_PREFIX.ectab" \
  "$INDEX_PREFIX.refinfo" \
  | tee "$RUN/index-cache-before-primary.txt"
```

All four `RES` and `PAGES` values must be zero. If not, run `sync` and the
targeted eviction again before proceeding.

Start lightweight CPU and block-device monitors, then execute the same mapping
command used by the high-memory Lambda:

```bash
stdbuf -oL iostat -xz 1 >"$RUN/iostat-primary.txt" &
IOSTAT_PID=$!
stdbuf -oL pidstat -dru -C 'piscem|sc_ref_mapper' 1 \
  >"$RUN/pidstat-primary.txt" &
PIDSTAT_PID=$!

set +e
/usr/bin/time -v -o "$RUN/piscem-primary.time" \
  "$PISCEM" map-sc \
  -i "$INDEX_PREFIX" \
  -g chromium_v3 \
  -1 "$R1" \
  -2 "$R2" \
  -t 6 \
  -o "$RUN/primary-output" \
  2>&1 | tee "$RUN/piscem-primary.log"
MAP_RC=${PIPESTATUS[0]}
set -e

kill "$IOSTAT_PID" "$PIDSTAT_PID" 2>/dev/null || true
wait "$IOSTAT_PID" "$PIDSTAT_PID" 2>/dev/null || true
test "$MAP_RC" -eq 0
```

Collect the primary result:

```bash
grep -E 'loading index from|done loading index|finished mapping' \
  "$RUN/piscem-primary.log"
cat "$RUN/piscem-primary.time"
cat "$RUN/primary-output/map_info.json"
stat -c '%n %s bytes' "$RUN/primary-output/"*

"$RADTK" view \
  --rad-type single-cell \
  --max-chunks 1 \
  --input "$RUN/primary-output/map.rad" \
  >/dev/null
```

Calculate:

- index load = `done loading index` minus `loading index from`;
- combined map/output = `finished mapping` minus `done loading index`;
- total wall time = GNU `time`'s elapsed value; and
- phase percentages using index load plus combined map/output as the
  denominator.

Piscem builds and writes RAD records inside its mapper workers. The combined
map/output interval is therefore not divisible into two serial wall-clock
phases using the stock log.

## 6. Run a warm-index control

Without evicting anything, repeat the command into a new output directory:

```bash
/usr/bin/time -v -o "$RUN/piscem-warm.time" \
  "$PISCEM" map-sc \
  -i "$INDEX_PREFIX" \
  -g chromium_v3 \
  -1 "$R1" \
  -2 "$R2" \
  -t 6 \
  -o "$RUN/warm-output" \
  2>&1 | tee "$RUN/piscem-warm.log"

grep -E 'loading index from|done loading index|finished mapping' \
  "$RUN/piscem-warm.log"
```

The cold-versus-warm index delta shows the maximum opportunity available from
retaining the index in cache. Do not compare only total times; thread
scheduling can cause small mapping variation.

## 7. Attribute RAD output blocking with a traced repeat

Run this only after the untraced baseline. `strace` changes timing, so its wall
time is diagnostic rather than the primary result.

```bash
sync
find "$INDEX_DIR" -maxdepth 1 -type f \
  -exec dd if={} iflag=nocache count=0 status=none \;

/usr/bin/time -v -o "$RUN/piscem-traced.time" \
  strace -f -ttt -T -yy \
  -e trace=openat,close,write,writev,pwrite64,pwritev,pwritev2,lseek \
  -o "$RUN/piscem-traced.strace" \
  "$PISCEM" map-sc \
  -i "$INDEX_PREFIX" \
  -g chromium_v3 \
  -1 "$R1" \
  -2 "$R2" \
  -t 6 \
  -o "$RUN/traced-output" \
  2>&1 | tee "$RUN/piscem-traced.log"
```

The following parser handles both complete and interleaved `writev` trace
records. It reports application bytes, call count, and cumulative time blocked
inside output syscalls:

```bash
awk '
function getdur(line, x) {
  x=line; sub(/^.*</, "", x); sub(/>$/, "", x); return x+0
}
function getret(line, x) {
  x=line; sub(/^.*\) = /, "", x); sub(/ .*/, "", x); return x+0
}
/ writev\([0-9]+</ {
  p=$0; sub(/^.*writev\([0-9]+</, "", p); sub(/>.*/, "", p)
  if ($0 ~ /unfinished/) { pending[$1]=p; next }
  count[p]++; bytes[p]+=getret($0); seconds[p]+=getdur($0); next
}
/<\.\.\. writev resumed>/ {
  p=pending[$1]
  count[p]++; bytes[p]+=getret($0); seconds[p]+=getdur($0)
  delete pending[$1]; next
}
/ write\([0-9]+</ {
  p=$0; sub(/^.*write\([0-9]+</, "", p); sub(/>.*/, "", p)
  count[p]++; bytes[p]+=getret($0); seconds[p]+=getdur($0)
}
END {
  for (p in count)
    if (p ~ /\/(map.rad|unmapped_bc_count.bin)$/)
      printf "%s calls=%d bytes=%.0f syscall_seconds=%.6f\n",
             p, count[p], bytes[p], seconds[p]
}
' "$RUN/piscem-traced.strace" | sort \
  | tee "$RUN/rad-write-summary.txt"
```

For `map.rad`, emitted bytes should equal final file size plus 8 bytes. The
extra bytes are the final chunk-count overwrite. Piscem does not call
`fsync(2)`, so syscall time measures application blocking against the page
cache, not forced durability.

## 8. Diagnose from evidence

Use the following rules as starting thresholds, not universal limits:

| Observation | Likely bottleneck or next action |
|---|---|
| Cold index load is under 5% of active Piscem time | Do not optimize index loading first |
| Cold load is large but warm load collapses | Cold storage/image/index placement; correlate with index reads in `iostat` |
| CPU stays near 600% while device utilization and await are low | Mapping or RAD serialization is CPU-bound |
| CPU is low while the FASTQ device is saturated | Input parsing is blocked on storage; compare warm and targeted cold-input runs |
| `map.rad` syscall time exceeds 10% and NVMe await/utilization rises | RAD output storage is a real bottleneck |
| Syscall time is low but CPU remains high | Profile Piscem CPU; RAD record construction may still be costly even though storage is not |
| S3 download dominates but Piscem is fast | Treat S3 staging as a separate pipeline optimization |

If CPU attribution is required, first try `perf record -g`/`perf report` on the
cloud host. If kernel policy prevents sampling, instrument Piscem with
thread-local counters around `write_to_rad_stream` and the mutex-protected
`out_info.rad_file << rad_w` block. Do not time every record with a contended
global atomic or logger.

After the six-thread result is understood, a warm-cache thread sweep at 1, 2,
4, 6, and the instance's intended production thread count will show whether
the mapper scales or reaches the shared RAD lock/storage ceiling. Use a fresh
output directory for every run.

## Expected correctness values

These are invariants or sanity checks, not cloud timing targets:

| Result | Expected value |
|---|---:|
| Read pairs | 4,000,000 |
| Mapped pairs | 2,438,983 |
| Percent mapped | 60.974575% |
| `map.rad` bytes | 73,492,437 |
| RAD chunks | 490 |

Multi-threaded chunk ordering can change between runs, so do not require the
RAD SHA-256 to match. Require `map_info.json` counts, output size, chunk count,
and successful `radtk view` parsing instead.

For orientation only, the local control loaded the cold index in 0.136 seconds,
spent 6.954 seconds in combined mapping/output, and completed in 7.13 seconds.
Its traced `map.rad` syscalls accumulated 62.517 ms. The cloud result should be
reported independently rather than described as faster or slower without the
host and cache evidence above.

## Return package

Report the following to the primary agent:

1. Instance type, CPU, memory, `/storage` device type, filesystem, and whether
   it is instance-store NVMe or EBS.
2. R1 and R2 download wall times.
3. The four pre-run `fincore` rows proving index cache state.
4. Cold and warm phase timestamps and GNU `time` summaries.
5. `map_info.json`, output sizes, and RAD validation result.
6. Average CPU utilization plus the relevant `iostat` device's utilization,
   throughput, and await during mapping.
7. Parsed RAD write-call count, bytes, and cumulative syscall seconds.
8. A one-paragraph conclusion naming the observed bottleneck and the next
   experiment that would falsify it.

Keep the large inputs and outputs under the fresh `$RUN` directory until the
primary agent confirms the evidence is sufficient. Then remove that exact run
directory; never clean `/storage` broadly.
