#!/usr/bin/env python3
"""Validate and split the confirmed FSSP corpus.

The split is content-addressed, not order-dependent: SHA-256 values whose
integer digest is divisible by five are held out. Manual regression fixtures
are always held out and are never allowed into the training TSV.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path


SPLIT_NAME = "sha256-mod5-v1"


def _label_from_name(path: Path) -> str:
    label = path.name.split("_", 1)[0]
    if len(label) != 5 or not label.isascii() or not label.isdigit():
        raise ValueError(f"invalid FSSP label: {path.name}")
    return label


def _read_fixture_tsv(path: Path) -> list[tuple[Path, str, str]]:
    rows: list[tuple[Path, str, str]] = []
    with path.open(encoding="utf-8") as stream:
        for line_number, raw in enumerate(stream, start=1):
            line = raw.rstrip("\n")
            if not line or (line_number == 1 and line.lower() == "file\tlabel"):
                continue
            fields = line.split("\t")
            if len(fields) != 2:
                raise ValueError(f"invalid regression TSV row {line_number}")
            image = Path(fields[0]).expanduser()
            if not image.is_absolute():
                image = path.parent / image
            image = image.resolve()
            label = fields[1]
            if not image.is_file():
                raise ValueError(f"regression image does not exist: {image}")
            if len(label) != 5 or not label.isascii() or not label.isdigit():
                raise ValueError(f"invalid regression label at row {line_number}")
            digest = hashlib.sha256(image.read_bytes()).hexdigest()
            rows.append((image, label, digest))
    return rows


def prepare_corpus(
    corpus: Path,
    train_tsv: Path,
    held_out_tsv: Path,
    minimum: int = 2_000,
    regression_tsv: Path | None = None,
) -> tuple[int, int]:
    """Validate a corpus and write deterministic train/held-out TSV files."""

    unique: dict[str, tuple[Path, str]] = {}
    for path in sorted(corpus.glob("*.png")):
        try:
            label = _label_from_name(path)
        except ValueError as error:
            raise ValueError(str(error)) from error
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        previous = unique.get(digest)
        if previous and previous[1] != label:
            raise ValueError(f"conflicting labels for SHA-256 {digest}")
        # `sorted` order makes duplicate same-label files deterministic.
        unique.setdefault(digest, (path.resolve(), label))

    if len(unique) < minimum:
        raise ValueError(
            f"need at least {minimum} unique images, found {len(unique)}"
        )

    fixtures: dict[str, tuple[Path, str]] = {}
    if regression_tsv:
        for image, label, digest in _read_fixture_tsv(regression_tsv):
            previous = fixtures.get(digest) or unique.get(digest)
            if previous and previous[1] != label:
                raise ValueError(f"conflicting labels for SHA-256 {digest}")
            fixtures.setdefault(digest, (image, label))

    # Manual fixtures override the corpus path for the same image. This keeps
    # the regression TSV useful on its own while preserving one SHA bucket.
    combined = dict(unique)
    combined.update(fixtures)
    held_out: dict[str, tuple[Path, str]] = dict(fixtures)
    train: dict[str, tuple[Path, str]] = {}
    for digest, row in sorted(combined.items()):
        if digest in fixtures or int(digest, 16) % 5 == 0:
            held_out.setdefault(digest, row)
        else:
            train[digest] = row

    if set(train) & set(held_out):
        raise AssertionError("SHA-256 overlap between train and held-out sets")
    write_tsv(train_tsv, sorted(train.values(), key=lambda row: row[0].name))
    write_tsv(held_out_tsv, sorted(held_out.values(), key=lambda row: row[0].name))
    return len(unique), len(held_out)


def write_tsv(path: Path, rows: list[tuple[Path, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = "file\tlabel\n" + "".join(
        f"{file}\t{label}\n" for file, label in rows
    )
    path.write_text(body, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--train-tsv", required=True, type=Path)
    parser.add_argument(
        "--test-tsv", "--held-out-tsv", dest="test_tsv", required=True, type=Path
    )
    parser.add_argument("--regression-tsv", type=Path)
    parser.add_argument("--minimum", type=int, default=2_000)
    args = parser.parse_args(argv)

    try:
        unique_count, held_out_count = prepare_corpus(
            corpus=args.corpus,
            train_tsv=args.train_tsv,
            held_out_tsv=args.test_tsv,
            minimum=args.minimum,
            regression_tsv=args.regression_tsv,
        )
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1

    train_count = len(args.train_tsv.read_text(encoding="utf-8").splitlines()) - 1
    print(
        f"split={SPLIT_NAME} unique={unique_count} "
        f"train={train_count} held_out={held_out_count}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
