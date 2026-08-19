# S3 RAD materializer

`s3-rad-materialize` builds one local `map.rad` directly from compatible RAD
shards stored in S3. It reads each RAD prelude with a small ranged request,
calculates the final layout, and concurrently writes each S3 payload into its
assigned output range with `pwrite(2)`.

Unlike `aws s3 sync` followed by `radtk cat`, it does not materialize the shard
files or reread them from local storage.

## Build

The executable requires a C++17 compiler, CMake, and the AWS SDK for C++ with
the S3 component. The repository installer builds a pinned SDK and executable:

```bash
bash install_scripts/install_s3_rad_materializer.sh
```

To use an existing AWS SDK installation:

```bash
cmake -S tools/s3-rad-materializer -B build/s3-rad-materializer \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/path/to/aws-sdk
cmake --build build/s3-rad-materializer --parallel
ctest --test-dir build/s3-rad-materializer --output-on-failure
```

## Run

Create a manifest with one S3 URI per line, in the exact order in which the RAD
record chunks must occur:

```text
s3://my-output-bucket/piscem_output/sample_p0/map.rad
s3://my-output-bucket/piscem_output/sample_p1/map.rad
s3://my-output-bucket/piscem_output/sample_p2/map.rad
```

Then run:

```bash
s3-rad-materialize \
  --manifest shards.txt \
  --output /storage/run/combined/map.rad \
  --region us-east-2 \
  --threads 32
```

Credentials use the normal AWS SDK provider chain. For a local named profile,
add `--profile PROFILE`. On the pipeline driver EC2 instance, omit `--profile`
so the instance role is used.

The output is written to `map.rad.partial` and atomically renamed only after
every byte range completes. Add `--fsync` when persistence across a machine
crash is required; the pipeline default matches the existing materializer's
close-without-fsync behavior. Requests are pinned to the S3 VersionId
when available and otherwise to the ETag seen during header inspection.

## PBMC 1K benchmark

The benchmark script compares the current materialization path with the ranged
materializer using the retained 17-shard PBMC 1K output:

```bash
AWS_PROFILE=uw bash scripts/benchmark_s3_rad_materializer.sh
```

Set `BENCHMARK_ROOT=/storage/...`, `PBMC_RAD_BUCKET=...`, or `THREADS=...` to
override its defaults. Large temporary RAD files are removed after successful
validation unless `KEEP_BENCHMARK_DATA=1` is set.
