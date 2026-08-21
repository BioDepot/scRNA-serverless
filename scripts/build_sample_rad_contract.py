#!/usr/bin/env python3
"""Join expected Lambda RAD folders to an explicit pair-to-sample manifest."""

from __future__ import annotations

import argparse
import csv
import re
import sys
from collections import Counter
from pathlib import Path


SHARD_FOLDER = re.compile(r"^(?P<pair>.+)_p(?P<shard>[0-9]+)$")
SAFE_SAMPLE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def read_sample_manifest(path: Path) -> dict[str, str]:
    pair_samples: dict[str, str] = {}
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        required = {"sample", "pair_name"}
        missing = required - set(reader.fieldnames or ())
        if missing:
            raise ValueError(
                f"sample manifest is missing required column(s): {', '.join(sorted(missing))}"
            )
        for line_number, row in enumerate(reader, start=2):
            sample = (row.get("sample") or "").strip()
            pair_name = (row.get("pair_name") or "").strip()
            if not sample or not pair_name:
                raise ValueError(f"empty sample or pair_name on line {line_number}")
            if not SAFE_SAMPLE.fullmatch(sample):
                raise ValueError(f"unsafe sample name {sample!r} on line {line_number}")
            if pair_name in pair_samples:
                raise ValueError(f"duplicate pair_name in sample manifest: {pair_name}")
            pair_samples[pair_name] = sample
    if not pair_samples:
        raise ValueError("sample manifest has no data rows")
    return pair_samples


def read_expected_folders(path: Path) -> list[str]:
    folders = sorted(
        {line.strip() for line in path.read_text().splitlines() if line.strip()}
    )
    if not folders:
        raise ValueError("expected-folder file has no entries")
    return folders


def natural_key(value: str) -> list[tuple[int, int | str]]:
    return [
        (0, int(part)) if part.isdigit() else (1, part)
        for part in re.split(r"([0-9]+)", value)
    ]


def build_contract(pair_samples: dict[str, str], folders: list[str]) -> list[tuple[str, str]]:
    rows: list[tuple[str, str, int]] = []
    seen_pairs: Counter[str] = Counter()
    for folder in folders:
        if "/" in folder or folder in {".", ".."}:
            raise ValueError(f"invalid expected folder: {folder}")
        match = SHARD_FOLDER.fullmatch(folder)
        if not match:
            raise ValueError(f"expected folder lacks a terminal _pN shard suffix: {folder}")
        pair_name = match.group("pair")
        if pair_name not in pair_samples:
            raise ValueError(
                f"expected folder {folder!r} maps to pair {pair_name!r}, "
                "which is absent from the sample manifest"
            )
        seen_pairs[pair_name] += 1
        rows.append((pair_samples[pair_name], folder, int(match.group("shard"))))

    absent_pairs = sorted(set(pair_samples) - set(seen_pairs), key=natural_key)
    if absent_pairs:
        preview = ", ".join(absent_pairs[:10])
        suffix = " ..." if len(absent_pairs) > 10 else ""
        raise ValueError(
            f"{len(absent_pairs)} manifest pair(s) have no expected Lambda folder: "
            f"{preview}{suffix}"
        )

    rows.sort(key=lambda row: (natural_key(row[0]), natural_key(row[1]), row[2]))
    return [(sample, folder) for sample, folder, _shard in rows]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample-manifest", type=Path, required=True)
    parser.add_argument("--expected-folders", type=Path, required=True)
    args = parser.parse_args()

    try:
        rows = build_contract(
            read_sample_manifest(args.sample_manifest),
            read_expected_folders(args.expected_folders),
        )
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    writer = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
    writer.writerow(("sample", "expected_folder"))
    writer.writerows(rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
