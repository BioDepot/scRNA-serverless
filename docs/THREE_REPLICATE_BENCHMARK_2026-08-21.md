# Three-replicate production benchmark

Each arm has three trials. All values are wall-clock seconds. Every ± value is the standard error of the mean (SE = sample SD / sqrt(n), n = 3).
The local baseline is Piscem with 32 threads on an m5dn.8xlarge. The asynchronous clock starts with the first NVMe-resident FASTQ decompressor and ends when the final RAD, or all 13 KO sample RADs, is materialized locally.
Alevin-fry is excluded from both arms because it is unchanged. Mean Lambda alignment overlaps other stages and is not additive.

## Exact trial measurements

The values below retain the precision recorded in the source TSV.

| Dataset | Trial | Local baseline | Split/upload | Mean Lambda alignment | Post-split before merge | Download/merge | Async total | Paired speedup |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| PBMC 1K | 1 | 81.370129 | 39.187000 | 18.929937667 | 20.798872 | 1.519214 | 61.505086 | 1.322982x |
| PBMC 1K | 2 | 80.492631 | 38.947000 | 19.489501778 | 19.452303 | 1.734723 | 60.134026 | 1.338554x |
| PBMC 1K | 3 | 80.395011 | 39.054000 | 20.570290167 | 21.332919 | 1.585268 | 61.972187 | 1.297276x |
| PBMC 10K | 1 | 781.662519 | 339.549000 | 21.173364503 | 21.165365 | 6.621013 | 367.335378 | 2.127926x |
| PBMC 10K | 2 | 779.353604 | 342.282000 | 21.443944528 | 23.608673 | 7.636214 | 373.526887 | 2.086473x |
| PBMC 10K | 3 | 780.488986 | 334.812000 | 21.771142453 | 25.964546 | 6.944222 | 367.720768 | 2.122505x |
| KO, 13 samples | 1 | 8696.991876 | 1215.181179 | 32.054538125 | 7.565293 | 91.035595 | 1313.782067 | 6.619813x |
| KO, 13 samples | 2 | 8736.309241 | 1208.066521 | 32.341702863 | 7.461217 | 92.666408 | 1308.194146 | 6.678144x |
| KO, 13 samples | 3 | 8749.730907 | 1223.935645 | 32.556917549 | 7.500613 | 90.363929 | 1321.800187 | 6.619556x |

## Mean stage times

Values are the arithmetic mean ± standard error across three trials.

| Dataset | Local baseline | Split/upload | Mean Lambda alignment | Post-split before merge | Download/merge | Async total | Speedup from arm means |
|---|---:|---:|---:|---:|---:|---:|---:|
| PBMC 1K | 80.753 ± 0.310 | 39.063 ± 0.069 | 19.663 ± 0.481 | 20.528 ± 0.560 | 1.613 ± 0.064 | 61.204 ± 0.552 | 1.319x |
| PBMC 10K | 780.502 ± 0.667 | 338.881 ± 2.182 | 21.463 ± 0.173 | 23.580 ± 1.385 | 7.067 ± 0.299 | 369.528 ± 2.003 | 2.112x |
| KO, 13 samples | 8727.677 ± 15.824 | 1215.728 ± 4.589 | 32.318 ± 0.146 | 7.509 ± 0.030 | 91.355 ± 0.684 | 1314.592 ± 3.949 | 6.639x |

## Distribution and paired speedup

| Dataset | Local median | Local range | Async median | Async range | Mean paired speedup ± standard error |
|---|---:|---:|---:|---:|---:|
| PBMC 1K | 80.493 | 80.395–81.370 | 61.505 | 60.134–61.972 | 1.320x ± 0.012 |
| PBMC 10K | 780.489 | 779.354–781.663 | 367.721 | 367.335–373.527 | 2.112x ± 0.013 |
| KO, 13 samples | 8736.309 | 8696.992–8749.731 | 1313.782 | 1308.194–1321.800 | 6.639x ± 0.019 |
