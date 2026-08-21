#!/usr/bin/env python3
"""Validate and summarize the three-trial production benchmark TSV."""

from __future__ import annotations

import argparse
import csv
import math
import statistics
from collections import defaultdict
from pathlib import Path


NUMERIC_FIELDS = (
    "baseline_seconds",
    "split_upload_seconds",
    "mean_lambda_alignment_seconds",
    "post_split_before_merge_seconds",
    "download_merge_seconds",
    "async_total_seconds",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="replicate TSV")
    parser.add_argument("--output", type=Path, help="write Markdown here instead of stdout")
    parser.add_argument("--expected-trials", type=int, default=3)
    return parser.parse_args()


def read_rows(path: Path, expected_trials: int) -> list[dict[str, object]]:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        required = {"dataset", "trial", *NUMERIC_FIELDS}
        missing = required.difference(reader.fieldnames or ())
        if missing:
            raise SystemExit(f"missing TSV columns: {', '.join(sorted(missing))}")
        rows: list[dict[str, object]] = []
        for line_number, raw in enumerate(reader, start=2):
            try:
                trial = int(raw["trial"])
                values = {name: float(raw[name]) for name in NUMERIC_FIELDS}
            except (TypeError, ValueError) as exc:
                raise SystemExit(f"invalid value on TSV line {line_number}: {exc}") from exc
            if not raw["dataset"]:
                raise SystemExit(f"empty dataset on TSV line {line_number}")
            if trial < 1:
                raise SystemExit(f"trial must be positive on TSV line {line_number}")
            if any(not math.isfinite(value) or value < 0 for value in values.values()):
                raise SystemExit(f"numeric values must be finite and nonnegative on TSV line {line_number}")
            if values["baseline_seconds"] == 0 or values["async_total_seconds"] == 0:
                raise SystemExit(f"baseline and async totals must be positive on TSV line {line_number}")
            stage_sum = (
                values["split_upload_seconds"]
                + values["post_split_before_merge_seconds"]
                + values["download_merge_seconds"]
            )
            if abs(stage_sum - values["async_total_seconds"]) > 0.002:
                raise SystemExit(
                    f"async stages differ from total by more than 2 ms on TSV line {line_number}"
                )
            rows.append({**raw, "trial": trial, **values})

    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        grouped[str(row["dataset"])].append(row)
    for dataset, dataset_rows in grouped.items():
        trials = [int(row["trial"]) for row in dataset_rows]
        if sorted(trials) != list(range(1, expected_trials + 1)):
            raise SystemExit(
                f"{dataset} must contain trials 1..{expected_trials} exactly once; found {sorted(trials)}"
            )
    return rows


def mean_sd(values: list[float]) -> tuple[float, float]:
    return statistics.mean(values), statistics.stdev(values) if len(values) > 1 else 0.0


def render(rows: list[dict[str, object]]) -> str:
    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        grouped[str(row["dataset"])].append(row)

    lines = [
        "# Three-replicate production benchmark",
        "",
        "Each arm has three trials. All values are wall-clock seconds; variability is reported as sample standard deviation (n - 1).",
        "The local baseline is Piscem with 32 threads on an m5dn.8xlarge. The asynchronous clock starts with the first NVMe-resident FASTQ decompressor and ends when the final RAD, or all 13 KO sample RADs, is materialized locally.",
        "Alevin-fry is excluded from both arms because it is unchanged. Mean Lambda alignment overlaps other stages and is not additive.",
        "",
        "| Dataset | Trial | Local baseline | Split/upload | Mean Lambda alignment | Post-split before merge | Download/merge | Async total | Paired speedup |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for dataset, dataset_rows in grouped.items():
        for row in sorted(dataset_rows, key=lambda item: int(item["trial"])):
            speedup = float(row["baseline_seconds"]) / float(row["async_total_seconds"])
            lines.append(
                f"| {dataset} | {row['trial']} | {float(row['baseline_seconds']):.3f} | "
                f"{float(row['split_upload_seconds']):.3f} | "
                f"{float(row['mean_lambda_alignment_seconds']):.3f} | "
                f"{float(row['post_split_before_merge_seconds']):.3f} | "
                f"{float(row['download_merge_seconds']):.3f} | "
                f"{float(row['async_total_seconds']):.3f} | {speedup:.3f}x |"
            )

    lines.extend(
        [
            "",
            "## Mean stage times",
            "",
            "Values are the arithmetic mean ± sample standard deviation across three trials.",
            "",
            "| Dataset | Local baseline | Split/upload | Mean Lambda alignment | Post-split before merge | Download/merge | Async total | Speedup from arm means |",
            "|---|---:|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for dataset, dataset_rows in grouped.items():
        values_by_field = {
            field: [float(row[field]) for row in dataset_rows] for field in NUMERIC_FIELDS
        }
        field_stats = {field: mean_sd(values) for field, values in values_by_field.items()}
        baseline = values_by_field["baseline_seconds"]
        async_total = values_by_field["async_total_seconds"]
        baseline_mean, baseline_sd = field_stats["baseline_seconds"]
        split_mean, split_sd = field_stats["split_upload_seconds"]
        lambda_mean, lambda_sd = field_stats["mean_lambda_alignment_seconds"]
        post_mean, post_sd = field_stats["post_split_before_merge_seconds"]
        merge_mean, merge_sd = field_stats["download_merge_seconds"]
        async_mean, async_sd = field_stats["async_total_seconds"]
        lines.append(
            f"| {dataset} | {baseline_mean:.3f} ± {baseline_sd:.3f} | "
            f"{split_mean:.3f} ± {split_sd:.3f} | "
            f"{lambda_mean:.3f} ± {lambda_sd:.3f} | "
            f"{post_mean:.3f} ± {post_sd:.3f} | "
            f"{merge_mean:.3f} ± {merge_sd:.3f} | "
            f"{async_mean:.3f} ± {async_sd:.3f} | {baseline_mean / async_mean:.3f}x |"
        )

    lines.extend(
        [
            "",
            "## Distribution and paired speedup",
            "",
            "| Dataset | Local median | Local range | Async median | Async range | Mean paired speedup ± sample SD |",
            "|---|---:|---:|---:|---:|---:|",
        ]
    )
    for dataset, dataset_rows in grouped.items():
        baseline = [float(row["baseline_seconds"]) for row in dataset_rows]
        async_total = [float(row["async_total_seconds"]) for row in dataset_rows]
        paired = [base / async_value for base, async_value in zip(baseline, async_total)]
        paired_mean, paired_sd = mean_sd(paired)
        lines.append(
            f"| {dataset} | {statistics.median(baseline):.3f} | "
            f"{min(baseline):.3f}–{max(baseline):.3f} | "
            f"{statistics.median(async_total):.3f} | "
            f"{min(async_total):.3f}–{max(async_total):.3f} | "
            f"{paired_mean:.3f}x ± {paired_sd:.3f} |"
        )
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    args = parse_args()
    report = render(read_rows(args.input, args.expected_trials))
    if args.output:
        args.output.write_text(report, encoding="utf-8")
    else:
        print(report, end="")


if __name__ == "__main__":
    main()
