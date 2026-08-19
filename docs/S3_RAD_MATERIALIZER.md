# Direct S3 RAD materialization

The serverless pipeline currently downloads every Lambda output with
`aws s3 sync` and then combines the local `map.rad` shards with `radtk cat`.
The feature implementation in `tools/s3-rad-materializer/` replaces those two
RAD-specific operations with concurrent S3 ranged GETs into one final file.

It does not replace the separate `unmapped_bc_count.bin` concatenation.

## How it works

1. Read an ordered manifest containing one `s3://bucket/key` per line.
2. Issue concurrent `HeadObject` and prefix-range requests.
3. Parse each variable-length RAD prelude through its file-level tag values.
4. Require every serialized prelude to match, excluding `num_chunks`.
5. Sum `num_chunks` and calculate every payload's destination offset.
6. Create `map.rad.partial`, write the combined prelude, and size the file.
7. Range-download each record payload directly into its non-overlapping output
   region with `pwrite(2)`.
8. Atomically rename the completed temporary file to `map.rad`.

Payload requests use the object's VersionId when available and otherwise an
`If-Match` condition with the ETag observed during inspection. A changed object
therefore fails the materialization instead of mixing versions.

The implementation preserves the exact record bytes. It does not parse,
deserialize, or rewrite any RAD chunks.

## PBMC 1K benchmark fixture

The retained Lambda output used by the benchmark is:

```text
s3://scrna-map-171440768238-us-east-2-p1krg-0819-1054/
```

It contains 17 `map.rad` shards for `pbmc_1k_v3_S1_L001`, numbered `p0`
through `p16`. The benchmark always uses numeric shard order for both methods.

Measured fixture properties:

| Property | Value |
|---|---:|
| S3 RAD objects | 17 |
| Aggregate S3 object bytes | 1,231,688,321 |
| Combined header bytes | 3,384,909 |
| Combined payload bytes | 1,174,144,868 |
| Final `map.rad` bytes | 1,177,529,777 |
| RAD chunks | 8,218 |

## Initial baseline

The following result was recorded on the development host using `/storage`,
the `uw` profile, and 32 requested workers (17 active workers):

| Path | Time |
|---|---:|
| `aws s3 sync` | 30.793 s |
| `radtk cat` | 0.543 s |
| Existing total | 31.336 s |
| Ranged materializer total | 25.855 s |
| End-to-end speedup | 1.212x |

The result shows that, for this fixture on this host, local `radtk cat` is only
about half a second because the freshly downloaded shards remain in the page
cache. Most of the current bottleneck is S3 materialization. The ranged writer
still removes the shard files and their local reread and reduced the measured
end-to-end time by 5.481 seconds (17.5%). Network measurements vary, so the
target pipeline EC2 instance should also be benchmarked before enabling this
path by default.

Both outputs had this SHA-256 digest and passed `cmp`:

```text
0317bac8c3d2420d74376f3520b0454408e8e723e39028e92342f0d52f7931f2
```

`radtk view --rad-type single-cell --max-chunks 1` also parsed the ranged
output successfully.

## Reproduce

Install the pinned S3-only AWS SDK and executable once:

```bash
bash install_scripts/install_s3_rad_materializer.sh
```

Run the comparison:

```bash
AWS_PROFILE=uw bash scripts/benchmark_s3_rad_materializer.sh
```

The large temporary files are removed after a successful run. Set
`KEEP_BENCHMARK_DATA=1` to retain them. Summary result files remain under
`/storage/s3-rad-materializer-benchmark/`.

## Pipeline integration boundary

The materializer should be invoked after all Lambda `output.txt` markers exist
and before alevin-fry. The driver should generate the ordered manifest from the
expected Lambda output folders, run `s3-rad-materialize` to create
`combined/map.rad`, and download only the non-RAD companion outputs required by
the pipeline.

The current pipeline path is deliberately unchanged on this benchmark branch.
Enabling the new implementation by default should follow a benchmark on the
actual driver EC2/NVMe configuration and installation of the binary in the
driver image.
