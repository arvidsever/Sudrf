#!/usr/bin/env python3
"""Validate and split the confirmed FSSP corpus by image SHA-256 (80/20)."""

import argparse
import hashlib
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--train-tsv", required=True, type=Path)
    parser.add_argument("--test-tsv", required=True, type=Path)
    parser.add_argument("--minimum", type=int, default=2_000)
    args = parser.parse_args()

    unique: dict[str, tuple[Path, str]] = {}
    for path in sorted(args.corpus.glob("*.png")):
        label = path.name.split("_", 1)[0]
        if len(label) != 5 or not label.isascii() or not label.isdigit():
            print(f"invalid FSSP label: {path.name}", file=sys.stderr)
            return 1
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        previous = unique.get(digest)
        if previous and previous[1] != label:
            print(f"conflicting labels for SHA-256 {digest}", file=sys.stderr)
            return 1
        unique[digest] = (path.resolve(), label)

    if len(unique) < args.minimum:
        print(f"need at least {args.minimum} unique images, found {len(unique)}", file=sys.stderr)
        return 1

    ranked = [unique[digest] for digest in sorted(unique)]
    train_count = len(ranked) * 4 // 5
    write_tsv(args.train_tsv, ranked[:train_count])
    write_tsv(args.test_tsv, ranked[train_count:])
    print(f"unique={len(ranked)} train={train_count} held_out={len(ranked) - train_count}")
    return 0


def write_tsv(path: Path, rows: list[tuple[Path, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = "file\tlabel\n" + "".join(f"{file}\t{label}\n" for file, label in rows)
    path.write_text(body, encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
