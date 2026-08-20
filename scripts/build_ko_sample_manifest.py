#!/usr/bin/env python3
"""Build the pair-level MSK KO sample manifest from the ENA file manifest."""

from __future__ import annotations

import argparse
import csv
import io
import re
from collections import Counter
from pathlib import Path


SAMPLE_ORDER = ("A", "B", "C", "D", "E", "F", "G_1", "G_2", "H", "I", "J", "L_1", "L_2")
MATE_PATTERN = re.compile(r"^(?P<pair>.+)_(?P<mate>R[12])_001\.fastq\.gz$")
OUTPUT_FIELDS = (
    "priority",
    "sample",
    "condition",
    "pair_name",
    "r1_filename",
    "r1_bytes",
    "r1_url",
    "r2_filename",
    "r2_bytes",
    "r2_url",
    "combined_bytes",
)


def sample_from_pair(pair_name: str) -> tuple[str, str]:
    fields = pair_name.split("_")
    if len(fields) < 3:
        raise ValueError(f"FASTQ pair name has fewer than three fields: {pair_name}")
    sample = f"{fields[0]}_{fields[2]}" if fields[0] in {"G", "L"} else fields[0]
    if sample not in SAMPLE_ORDER:
        raise ValueError(f"unexpected sample {sample!r} derived from {pair_name}")
    return sample, fields[1]


def build_rows(input_path: Path) -> list[dict[str, str | int]]:
    pairs: dict[str, dict[str, dict[str, str]]] = {}
    with input_path.open(newline="") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            match = MATE_PATTERN.match(row["filename"])
            if not match:
                raise ValueError(f"unexpected KO FASTQ filename: {row['filename']}")
            pair_name = match.group("pair")
            mate = match.group("mate").lower()
            if mate in pairs.setdefault(pair_name, {}):
                raise ValueError(f"duplicate {mate.upper()} for {pair_name}")
            size = int(row["bytes"])
            if size <= 0:
                raise ValueError(f"non-positive byte count for {row['filename']}")
            pairs[pair_name][mate] = row

    rows: list[dict[str, str | int]] = []
    for pair_name, mates in pairs.items():
        if set(mates) != {"r1", "r2"}:
            raise ValueError(f"incomplete R1/R2 pair {pair_name}: {sorted(mates)}")
        sample, condition = sample_from_pair(pair_name)
        r1 = mates["r1"]
        r2 = mates["r2"]
        combined_bytes = int(r1["bytes"]) + int(r2["bytes"])
        rows.append(
            {
                "priority": 0,
                "sample": sample,
                "condition": condition,
                "pair_name": pair_name,
                "r1_filename": r1["filename"],
                "r1_bytes": int(r1["bytes"]),
                "r1_url": r1["url"],
                "r2_filename": r2["filename"],
                "r2_bytes": int(r2["bytes"]),
                "r2_url": r2["url"],
                "combined_bytes": combined_bytes,
            }
        )

    rows.sort(key=lambda row: (-int(row["combined_bytes"]), str(row["pair_name"])))
    for priority, row in enumerate(rows, start=1):
        row["priority"] = priority

    counts = Counter(str(row["sample"]) for row in rows)
    missing = set(SAMPLE_ORDER) - set(counts)
    if missing:
        raise ValueError(f"samples without FASTQ pairs: {sorted(missing)}")
    if len(rows) != 130:
        raise ValueError(f"expected 130 complete KO pairs, found {len(rows)}")
    return rows


def render(rows: list[dict[str, str | int]]) -> str:
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=OUTPUT_FIELDS, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


def main() -> int:
    scripts_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=scripts_dir / "ko_ena_r1r2.tsv")
    parser.add_argument("--output", type=Path, default=scripts_dir / "ko_sample_pairs.tsv")
    parser.add_argument("--check", action="store_true", help="fail if OUTPUT is not current")
    args = parser.parse_args()

    rendered = render(build_rows(args.input))
    if args.check:
        if not args.output.exists() or args.output.read_text() != rendered:
            raise SystemExit(f"{args.output} is missing or stale")
        return 0

    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(rendered)
    temporary.replace(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
