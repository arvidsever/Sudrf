#!/usr/bin/env python3
"""Validate a confirmed FSSP corpus and create stable train/validation/exam TSVs.

The bucket is derived from the image bytes, so adding a new image never moves
an existing image between sets:

* SHA-256 remainder 1--4 and 6--9: training;
* remainder 5: validation (used to choose the checkpoint);
* remainder 0: exam (read only after CoreML conversion).

Manual regression fixtures are always placed in the exam set and are never
allowed into training or validation.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path


SPLIT_NAME = "sha256-mod10-v2"
TRAIN_BUCKETS = frozenset({1, 2, 3, 4, 6, 7, 8, 9})
VALIDATION_BUCKET = 5
EXAM_BUCKET = 0


def _valid_label(label: str) -> bool:
    return len(label) == 5 and label.isascii() and label.isdigit()


def _label_from_name(path: Path) -> str:
    label = path.name.split("_", 1)[0]
    if not _valid_label(label):
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
            if not _valid_label(label):
                raise ValueError(f"invalid regression label at row {line_number}")
            digest = hashlib.sha256(image.read_bytes()).hexdigest()
            rows.append((image, label, digest))
    return rows


def prepare_corpus(
    corpus: Path,
    train_tsv: Path,
    validation_tsv: Path,
    exam_tsv: Path,
    minimum: int = 2_000,
    regression_tsv: Path | None = None,
) -> tuple[int, int, int, int]:
    """Validate *corpus* and write stable train/validation/exam TSV files.

    The return value is ``(unique_corpus, train, validation, exam)``. Fixture
    images not present in ``corpus`` are included in ``exam`` but not in the
    unique corpus count; that keeps the corpus gate and the fixture gate
    independent.
    """

    unique: dict[str, tuple[Path, str]] = {}
    for path in sorted(corpus.glob("*.png")):
        label = _label_from_name(path)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        previous = unique.get(digest)
        if previous and previous[1] != label:
            raise ValueError(f"conflicting labels for SHA-256 {digest}")
        # Sorted paths make duplicate, same-label files deterministic.
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

    combined = dict(unique)
    combined.update(fixtures)
    train: dict[str, tuple[Path, str]] = {}
    validation: dict[str, tuple[Path, str]] = {}
    exam: dict[str, tuple[Path, str]] = dict(fixtures)
    for digest, row in sorted(combined.items()):
        bucket = int(digest, 16) % 10
        if digest in fixtures or bucket == EXAM_BUCKET:
            exam.setdefault(digest, row)
        elif bucket == VALIDATION_BUCKET:
            validation[digest] = row
        elif bucket in TRAIN_BUCKETS:
            train[digest] = row
        else:
            raise AssertionError(f"unassigned SHA bucket: {bucket}")

    if (set(train) & set(validation)) or (set(train) & set(exam)) or (
        set(validation) & set(exam)
    ):
        raise AssertionError("SHA-256 overlap between corpus splits")

    write_tsv(train_tsv, sorted(train.values(), key=lambda row: row[0].name))
    write_tsv(
        validation_tsv,
        sorted(validation.values(), key=lambda row: row[0].name),
    )
    write_tsv(exam_tsv, sorted(exam.values(), key=lambda row: row[0].name))
    return len(unique), len(train), len(validation), len(exam)


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
    parser.add_argument("--validation-tsv", required=True, type=Path)
    parser.add_argument(
        "--exam-tsv", "--test-tsv", "--held-out-tsv",
        dest="exam_tsv", required=True, type=Path,
    )
    parser.add_argument("--regression-tsv", type=Path)
    parser.add_argument("--minimum", type=int, default=2_000)
    args = parser.parse_args(argv)

    try:
        unique_count, train_count, validation_count, exam_count = prepare_corpus(
            corpus=args.corpus,
            train_tsv=args.train_tsv,
            validation_tsv=args.validation_tsv,
            exam_tsv=args.exam_tsv,
            minimum=args.minimum,
            regression_tsv=args.regression_tsv,
        )
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1

    print(
        f"split={SPLIT_NAME} unique={unique_count} train={train_count} "
        f"validation={validation_count} exam={exam_count}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
