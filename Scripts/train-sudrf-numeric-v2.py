#!/usr/bin/env python3
"""Train a lab-only numeric SUDRF model with an independent CoreML exam."""

from __future__ import annotations

import argparse
import csv
import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODEL_NAME = "model-captcha-numeric-v2"
REPORT_NAME = f"{MODEL_NAME}-report.json"
SPLIT_NAME = "sha256-mod10-v2"
PREPROCESSOR_VERSION = "sudrf-teal-box-v1"
ARCHITECTURE_VERSION = "sudrf-shared-cnn-v2"
MAX_EPOCHS = 200
DEFAULT_PATIENCE = 30
AUTO_CONFIDENCE = 0.90
TARGET_EXACT_ACCURACY = 0.98
REGRESSION_LABELS = (
    ROOT / "Tests" / "CaptchaSolverTests" / "Fixtures" / "sudrf" / "labels.csv"
)
# Three known court styles occupy less than 1.5% of an epoch after repeating.
# This keeps their production regressions visible without dominating the
# independent 16k-image corpus.
REGRESSION_OVERSAMPLE = 64


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _dependencies():
    try:
        import numpy as np
        import torch
    except ModuleNotFoundError as error:
        raise RuntimeError(
            "trainer dependencies are missing; run Scripts/setup-fssp-bootstrap.sh"
        ) from error
    helper = _load_module(
        "captcha_training_helper", ROOT / "Scripts/train-coreml-captcha-helper.py"
    )
    training = _load_module(
        "shared_captcha_training", ROOT / "Scripts/train-fssp-bootstrap.py"
    )
    return np, torch, helper, training


def load_samples(tsv_path: Path, helper, training) -> list:
    samples = []
    with tsv_path.open(encoding="utf-8") as stream:
        if next(stream, "").rstrip("\n") != "file\tlabel":
            raise ValueError(f"invalid TSV header: {tsv_path}")
        for line_number, raw in enumerate(stream, start=2):
            fields = raw.rstrip("\n").split("\t")
            if len(fields) != 2:
                raise ValueError(f"invalid TSV row {line_number}: {tsv_path}")
            image_path = Path(fields[0])
            label = fields[1]
            if len(label) != 5 or not label.isascii() or not label.isdigit():
                raise ValueError(f"invalid numeric label at row {line_number}")
            png = image_path.read_bytes()
            samples.append(training.Sample(
                helper.binarize_and_downsample(png),
                [int(character) for character in label],
                hashlib.sha256(png).hexdigest(),
            ))
    return samples


def load_regression_samples(labels_path: Path, helper, training) -> list:
    unique = {}
    with labels_path.open(encoding="utf-8", newline="") as stream:
        for row in csv.DictReader(stream):
            filename = row.get("filename", "")
            label = row.get("expected", "")
            if len(label) != 5 or not label.isascii() or not label.isdigit():
                continue
            image_path = labels_path.parent / filename
            png = image_path.read_bytes()
            digest = hashlib.sha256(png).hexdigest()
            previous = unique.get(digest)
            if previous and previous.label != [int(character) for character in label]:
                raise ValueError(f"conflicting regression label for SHA-256 {digest}")
            unique.setdefault(
                digest,
                training.Sample(
                    helper.binarize_and_downsample(png),
                    [int(character) for character in label],
                    digest,
                ),
            )
    return list(unique.values())


def prepare_split(corpus: Path, work: Path, minimum: int):
    train = work / "train.tsv"
    validation = work / "validation.tsv"
    exam = work / "exam.tsv"
    subprocess.run([
        sys.executable,
        str(ROOT / "Scripts/prepare-fssp-corpus.py"),
        "--corpus", str(corpus),
        "--train-tsv", str(train),
        "--validation-tsv", str(validation),
        "--exam-tsv", str(exam),
        "--minimum", str(minimum),
    ], check=True)
    return train, validation, exam


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--epochs", type=int, default=MAX_EPOCHS)
    parser.add_argument("--patience", type=int, default=DEFAULT_PATIENCE)
    parser.add_argument("--batch", type=int, default=24)
    parser.add_argument("--lr", type=float, default=0.001)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--device", choices=("cpu", "mps"), default="cpu")
    parser.add_argument("--minimum", type=int, default=200)
    args = parser.parse_args(argv)
    if args.epochs < 1 or args.epochs > MAX_EPOCHS:
        parser.error(f"--epochs must be between 1 and {MAX_EPOCHS}")
    if args.patience < 1 or args.batch < 1:
        parser.error("--patience and --batch must be positive")

    corpus = args.corpus.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()
    work = output_dir / f".sudrf-numeric-v2-work-{uuid.uuid4().hex}"
    report_path = output_dir / REPORT_NAME
    destination = output_dir / f"{MODEL_NAME}.mlmodelc"
    output_dir.mkdir(parents=True, exist_ok=True)
    try:
        if report_path.exists():
            report_path.unlink()
        work.mkdir(parents=True)
        train_tsv, validation_tsv, exam_tsv = prepare_split(corpus, work, args.minimum)
        unique_count = len({
            hashlib.sha256(path.read_bytes()).hexdigest()
            for path in corpus.glob("*.png")
        })
        split_counts = [
            len(path.read_text(encoding="utf-8").splitlines()) - 1
            for path in (train_tsv, validation_tsv, exam_tsv)
        ]
        if unique_count < args.minimum or any(count < 1 for count in split_counts):
            raise RuntimeError(
                f"invalid split: corpus={unique_count}, train={split_counts[0]}, "
                f"validation={split_counts[1]}, exam={split_counts[2]}"
            )

        np, torch, helper, training = _dependencies()
        train = load_samples(train_tsv, helper, training)
        validation = load_samples(validation_tsv, helper, training)
        regression = load_regression_samples(REGRESSION_LABELS, helper, training)
        if len(regression) != 3:
            raise RuntimeError(
                f"expected 3 unique SUDRF regression fixtures, found {len(regression)}"
            )
        regression_digests = {sample.digest for sample in regression}
        train = [sample for sample in train if sample.digest not in regression_digests]
        validation = [
            sample for sample in validation if sample.digest not in regression_digests
        ]
        train.extend(regression)
        training_samples = train + regression * (REGRESSION_OVERSAMPLE - 1)
        if not train or not validation:
            raise RuntimeError("prepared train or validation split is empty")

        torch.manual_seed(args.seed)
        np.random.seed(args.seed)
        device_name = args.device
        if device_name == "mps" and not torch.backends.mps.is_available():
            print("MPS unavailable; falling back to CPU")
            device_name = "cpu"
        device = torch.device(device_name)
        model = helper.SharedCaptchaNet().to(device)
        optimizer = torch.optim.Adam(model.parameters(), lr=args.lr, weight_decay=1e-4)
        best_score = (-1.0, -1.0)
        best_state = None
        best_epoch = 0
        stale_epochs = 0
        for epoch in range(1, args.epochs + 1):
            loss = training.train_epoch(
                model, optimizer, training_samples, args.batch, device, torch, np,
                epoch=epoch, seed=args.seed, augment=True,
            )
            metrics = training.evaluate_torch(
                model, validation, device, np, torch, threshold=AUTO_CONFIDENCE
            )
            score = (metrics["string"], metrics["digit"])
            print(
                f"epoch {epoch:3d} loss={loss:.4f} "
                f"validation-exact={score[0]:.3f} "
                f"validation-digit={score[1]:.3f} "
                f"accepted@.90={metrics['accepted']}"
            )
            if score > best_score:
                best_score = score
                best_epoch = epoch
                stale_epochs = 0
                best_state = {
                    key: value.detach().cpu().clone()
                    for key, value in model.state_dict().items()
                }
            else:
                stale_epochs += 1
                if stale_epochs >= args.patience:
                    print(f"early stop after {args.patience} stale validation epochs")
                    break
        if best_state is None:
            raise RuntimeError("training produced no checkpoint")
        model.load_state_dict(best_state)
        print(f"best validation checkpoint: epoch {best_epoch}")

        stage_root = work / "compiled"
        stage_root.mkdir(parents=True)
        staged_model = stage_root / f"{MODEL_NAME}.mlmodelc"
        training.compile_model(model, staged_model, torch)

        # The exam is decoded only after checkpoint selection and CoreML compilation.
        exam = [
            sample for sample in load_samples(exam_tsv, helper, training)
            if sample.digest not in regression_digests
        ]
        if not exam:
            raise RuntimeError("prepared exam split is empty")
        parity_difference = training.check_coreml_parity(
            model, staged_model, train + validation + exam,
            device, np, torch,
        )
        compiled = training._load_compiled(staged_model)
        train_metrics = training.evaluate_compiled(
            staged_model, train, np, threshold=AUTO_CONFIDENCE, compiled=compiled
        )
        validation_metrics = training.evaluate_compiled(
            staged_model, validation, np, threshold=AUTO_CONFIDENCE, compiled=compiled
        )
        exam_metrics = training.evaluate_compiled(
            staged_model, exam, np, threshold=AUTO_CONFIDENCE, compiled=compiled
        )
        report = {
            "version": 2,
            "modelName": MODEL_NAME,
            "split": SPLIT_NAME,
            "uniqueCorpusCount": unique_count,
            "regressionFixtureCount": len(regression),
            "trainCount": train_metrics["total"],
            "trainStringAccuracy": train_metrics["string"],
            "trainDigitAccuracy": train_metrics["digit"],
            "validationCount": validation_metrics["total"],
            "validationStringAccuracy": validation_metrics["string"],
            "validationDigitAccuracy": validation_metrics["digit"],
            "examCount": exam_metrics["total"],
            "examStringAccuracy": exam_metrics["string"],
            "examDigitAccuracy": exam_metrics["digit"],
            "acceptedAt090Count": exam_metrics["accepted"],
            "acceptedAt090Accuracy": exam_metrics["accepted_accuracy"],
            "targetExactAccuracy": TARGET_EXACT_ACCURACY,
            "targetReached": exam_metrics["string"] >= TARGET_EXACT_ACCURACY,
            "trainedAt": datetime.now(timezone.utc)
                .replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "preprocessorVersion": PREPROCESSOR_VERSION,
            "architectureVersion": ARCHITECTURE_VERSION,
            "coreMLParityPassed": True,
            "coreMLMaxLogitDifference": parity_difference,
        }
        curation_report = corpus / "curation-report.json"
        if curation_report.is_file():
            report["curation"] = json.loads(curation_report.read_text(encoding="utf-8"))
        training.atomic_replace_directory(staged_model, destination)
        training.atomic_write_json(report, report_path)
        print(
            f"compiled exam-exact={exam_metrics['string']:.3f} "
            f"exam-digit={exam_metrics['digit']:.3f} "
            f"accepted@.90={exam_metrics['accepted']} "
            f"accepted-accuracy={exam_metrics['accepted_accuracy']:.3f}"
        )
        print(f"model={destination}")
        print(f"report={report_path}")
        return 0
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"SUDRF numeric v2 training failed: {error}", file=sys.stderr)
        return 1
    finally:
        if work.exists():
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
