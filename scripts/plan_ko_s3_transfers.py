#!/usr/bin/env python3
"""Print, but never execute, the KO FASTQ-to-S3 transfer plan."""

from __future__ import annotations

import argparse
import csv
import shlex
import sys
from pathlib import Path


GIB = 1024**3


def shell_join(parts: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in parts)


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    required = {
        "priority",
        "sample",
        "pair_name",
        "r1_filename",
        "r1_bytes",
        "r2_filename",
        "r2_bytes",
        "combined_bytes",
    }
    missing = required - set(rows[0] if rows else ())
    if missing:
        raise ValueError(f"manifest is missing column(s): {', '.join(sorted(missing))}")
    if len(rows) != 130:
        raise ValueError(f"expected 130 KO pairs, found {len(rows)}")
    rows.sort(key=lambda row: (-int(row["combined_bytes"]), row["pair_name"]))
    return rows


def main() -> int:
    scripts_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(
        description="Print exact direct-upload and split/upload commands; execute nothing."
    )
    parser.add_argument("--manifest", type=Path, default=scripts_dir / "ko_sample_pairs.tsv")
    parser.add_argument("--fastq-dir", type=Path, default=Path("/mnt/nvme/datasets/ko/fastqs"))
    parser.add_argument("--fastq-bucket", default="$INPUT_FASTQ_BUCKET")
    parser.add_argument("--input-txt-bucket", default="$INPUT_TXT_BUCKET")
    parser.add_argument("--s3-prefix", default="ko")
    parser.add_argument("--region", default="us-east-2")
    parser.add_argument("--cores", type=int, default=32)
    parser.add_argument("--direct-gzip-max-bytes", type=int, default=GIB)
    parser.add_argument("--split-lines", type=int, default=16_000_000)
    parser.add_argument("--check-local", action="store_true")
    args = parser.parse_args()

    if args.cores <= 0:
        parser.error("--cores must be positive")
    if args.direct_gzip_max_bytes <= 0:
        parser.error("--direct-gzip-max-bytes must be positive")
    if args.split_lines <= 0 or args.split_lines % 4:
        parser.error("--split-lines must be positive and divisible by four")

    try:
        rows = read_rows(args.manifest)
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    if args.check_local:
        errors: list[str] = []
        for row in rows:
            for filename_field, bytes_field in (
                ("r1_filename", "r1_bytes"),
                ("r2_filename", "r2_bytes"),
            ):
                path = args.fastq_dir / row[filename_field]
                if not path.is_file():
                    errors.append(f"missing {path}")
                elif path.stat().st_size != int(row[bytes_field]):
                    errors.append(
                        f"size mismatch {path}: expected {row[bytes_field]}, "
                        f"found {path.stat().st_size}"
                    )
        if errors:
            print("ERROR: local FASTQ validation failed", file=sys.stderr)
            for error in errors[:20]:
                print(f"  {error}", file=sys.stderr)
            if len(errors) > 20:
                print(f"  ... and {len(errors) - 20} more", file=sys.stderr)
            return 1

    direct = [row for row in rows if int(row["combined_bytes"]) < args.direct_gzip_max_bytes]
    split = [row for row in rows if int(row["combined_bytes"]) >= args.direct_gzip_max_bytes]
    split_file_count = len(split) * 2
    decompressor = "gzip"
    decompressor_threads = 1
    if split_file_count < args.cores:
        decompressor_threads = min(8, args.cores // split_file_count)
        if decompressor_threads > 1:
            decompressor = "rapidgzip"
        else:
            decompressor_threads = 1
    max_pair_workers = max(1, args.cores // (2 * decompressor_threads))

    print("# DRY RUN ONLY: the planner executes no AWS, gzip, or rapidgzip command.")
    print(f"# pairs={len(rows)} direct={len(direct)} split={len(split)}")
    print(
        f"# direct_cutoff_bytes={args.direct_gzip_max_bytes} "
        f"split_lines={args.split_lines} reads_per_shard={args.split_lines // 4}"
    )
    print(
        f"# split_files={split_file_count} cores={args.cores} "
        f"decompressor={decompressor} threads_per_file={decompressor_threads} "
        f"concurrent_pair_workers={max_pair_workers}"
    )
    print("# Large split pairs are listed first. Launch at most the stated pair workers concurrently.")
    print("# R1 and R2 release their cores independently. Launch the next queued pair")
    print("# as soon as any two cores are free; they need not come from the same prior pair.")
    print()
    print("# SPLIT/UPLOAD COMMANDS")
    for index, row in enumerate(split):
        command = [
            "env",
            f"FASTQ_DECOMPRESSOR={decompressor}",
            f"DECOMP_THREADS={decompressor_threads}",
            "bash",
            str(scripts_dir / "split_upload_trigger_local.sh"),
            args.fastq_bucket,
            str(args.fastq_dir / row["r1_filename"]),
            str(args.fastq_dir / row["r2_filename"]),
            f"{args.s3_prefix}/{row['pair_name']}",
            args.input_txt_bucket,
            str(args.split_lines),
        ]
        print(
            f"# queue_position={index + 1} priority={row['priority']} "
            f"sample={row['sample']} bytes={row['combined_bytes']}"
        )
        print(shell_join(command))

    print()
    print("# DIRECT GZIP UPLOAD/TRIGGER COMMANDS")
    print("# For each pair, run both aws s3 cp commands concurrently, wait for both,")
    print("# then publish the two-line input.txt last. Publishing input.txt is the trigger.")
    print(shell_join(["mkdir", "-p", "/mnt/nvme/datasets/ko/manifests"]))
    for row in direct:
        pair_name = row["pair_name"]
        r1_uri = f"s3://{args.fastq_bucket}/{args.s3_prefix}/{row['r1_filename']}"
        r2_uri = f"s3://{args.fastq_bucket}/{args.s3_prefix}/{row['r2_filename']}"
        manifest_path = f"/mnt/nvme/datasets/ko/manifests/{pair_name}_p0_input.txt"
        manifest_uri = (
            f"s3://{args.input_txt_bucket}/{args.s3_prefix}/{pair_name}_p0_input.txt"
        )
        print(
            f"# priority={row['priority']} sample={row['sample']} "
            f"bytes={row['combined_bytes']}"
        )
        r1_command = (
            shell_join(
                [
                    "aws",
                    "s3",
                    "cp",
                    str(args.fastq_dir / row["r1_filename"]),
                    r1_uri,
                    "--region",
                    args.region,
                    "--only-show-errors",
                    "--no-progress",
                ]
            )
        )
        r2_command = (
            shell_join(
                [
                    "aws",
                    "s3",
                    "cp",
                    str(args.fastq_dir / row["r2_filename"]),
                    r2_uri,
                    "--region",
                    args.region,
                    "--only-show-errors",
                    "--no-progress",
                ]
            )
        )
        print(f"{r1_command} & r1_pid=$!")
        print(f"{r2_command} & r2_pid=$!")
        print('wait "$r1_pid"')
        print('wait "$r2_pid"')
        print(f"printf '%s\\n%s\\n' {shlex.quote(r1_uri)} {shlex.quote(r2_uri)} > {shlex.quote(manifest_path)}")
        print(
            shell_join(
                [
                    "aws",
                    "s3",
                    "cp",
                    manifest_path,
                    manifest_uri,
                    "--region",
                    args.region,
                    "--only-show-errors",
                    "--no-progress",
                ]
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
