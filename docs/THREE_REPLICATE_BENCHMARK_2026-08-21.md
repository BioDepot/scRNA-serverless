# Three-replicate production benchmark

Each arm has three trials. All values are wall-clock seconds; variability is reported as sample standard deviation (n - 1).
The local baseline is Piscem with 32 threads on an m5dn.8xlarge. The asynchronous clock starts with the first NVMe-resident FASTQ decompressor and ends when the final RAD, or all 13 KO sample RADs, is materialized locally.
Alevin-fry is excluded from both arms because it is unchanged. Mean Lambda alignment overlaps other stages and is not additive.

| Dataset | Trial | Local baseline | Split/upload | Mean Lambda alignment | Post-split before merge | Download/merge | Async total | Paired speedup |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| PBMC 1K | 1 | 81.370 | 39.187 | 18.930 | 20.799 | 1.519 | 61.505 | 1.323x |
| PBMC 1K | 2 | 80.493 | 38.947 | 19.490 | 19.452 | 1.735 | 60.134 | 1.339x |
| PBMC 1K | 3 | 80.395 | 39.054 | 20.570 | 21.333 | 1.585 | 61.972 | 1.297x |
| PBMC 10K | 1 | 781.663 | 339.549 | 21.173 | 21.165 | 6.621 | 367.335 | 2.128x |
| PBMC 10K | 2 | 779.354 | 342.282 | 21.444 | 23.609 | 7.636 | 373.527 | 2.086x |
| PBMC 10K | 3 | 780.489 | 334.812 | 21.771 | 25.965 | 6.944 | 367.721 | 2.123x |
| KO, 13 samples | 1 | 8696.992 | 1215.181 | 32.055 | 7.565 | 91.036 | 1313.782 | 6.620x |
| KO, 13 samples | 2 | 8736.309 | 1208.067 | 32.342 | 7.461 | 92.666 | 1308.194 | 6.678x |
| KO, 13 samples | 3 | 8749.731 | 1223.936 | 32.557 | 7.501 | 90.364 | 1321.800 | 6.620x |

## Mean stage times

Values are the arithmetic mean ± sample standard deviation across three trials.

| Dataset | Local baseline | Split/upload | Mean Lambda alignment | Post-split before merge | Download/merge | Async total | Speedup from arm means |
|---|---:|---:|---:|---:|---:|---:|---:|
| PBMC 1K | 80.753 ± 0.537 | 39.063 ± 0.120 | 19.663 ± 0.834 | 20.528 ± 0.969 | 1.613 ± 0.110 | 61.204 ± 0.955 | 1.319x |
| PBMC 10K | 780.502 ± 1.155 | 338.881 ± 3.780 | 21.463 ± 0.299 | 23.580 ± 2.400 | 7.067 ± 0.519 | 369.528 ± 3.469 | 2.112x |
| KO, 13 samples | 8727.677 ± 27.409 | 1215.728 ± 7.949 | 32.318 ± 0.252 | 7.509 ± 0.053 | 91.355 ± 1.184 | 1314.592 ± 6.839 | 6.639x |

## Distribution and paired speedup

| Dataset | Local median | Local range | Async median | Async range | Mean paired speedup ± sample SD |
|---|---:|---:|---:|---:|---:|
| PBMC 1K | 80.493 | 80.395–81.370 | 61.505 | 60.134–61.972 | 1.320x ± 0.021 |
| PBMC 10K | 780.489 | 779.354–781.663 | 367.721 | 367.335–373.527 | 2.112x ± 0.023 |
| KO, 13 samples | 8736.309 | 8696.992–8749.731 | 1313.782 | 1308.194–1321.800 | 6.639x ± 0.034 |
