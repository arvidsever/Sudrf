#!/usr/bin/env python3
"""Train and atomically publish the lab-only FSSP bootstrap model.

The script intentionally owns the FSSP workflow instead of reusing the
production model names:

    python3 Scripts/train-fssp-bootstrap.py \
        --corpus "$HOME/Library/Application Support/Sudrf/captcha-training/solved-fssp" \
        --output-dir "$HOME/Library/Application Support/Sudrf/captcha-training"

It prepares the stable SHA bucket split, trains the existing five-head
architecture, compiles CoreML, evaluates the compiled model itself, and only
then replaces `model-captcha-fssp-bootstrap.mlmodelc/` and its report. A
failed conversion or compiled-model evaluation never creates an eligibility
report.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PREPROCESSOR_VERSION = "fssp-alpha-box-v2"
MODEL_NAME = "model-captcha-fssp-bootstrap"
REPORT_NAME = f"{MODEL_NAME}-report.json"
SPLIT_NAME = "sha256-mod5-v1"
SOURCE_WIDTH, SOURCE_HEIGHT = 240, 80
MASK_WIDTH, MASK_HEIGHT = 64, 20


def _load_dependencies():
    """Load the pinned ML stack only after argument/corpus validation."""

    try:
        import numpy as np
        import torch
        from PIL import Image
    except ModuleNotFoundError as error:
        raise RuntimeError(
            "FSSP trainer dependencies are missing; run "
            "Scripts/setup-fssp-bootstrap.sh first"
        ) from error

    helper_path = ROOT / "Scripts" / "train-coreml-captcha-helper.py"
    spec = importlib.util.spec_from_file_location("captcha_training_helper", helper_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load training architecture: {helper_path}")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    return np, torch, Image, helper


def fssp_full_frame_box_average(png_bytes: bytes, np_module, image_module):
    """Return the exact 64x20 FSSP mask used by Swift inference.

    No resize, crop, threshold, or interpolation is performed. Each source
    pixel contributes alpha/255 and each output cell is the arithmetic mean
    over its deterministic integer range.
    """

    from io import BytesIO

    with image_module.open(BytesIO(png_bytes)) as image:
        if image.size != (SOURCE_WIDTH, SOURCE_HEIGHT):
            raise ValueError(
                f"FSSP CAPTCHA must be 240x80, got {image.width}x{image.height}"
            )
        rgba = np_module.asarray(image.convert("RGBA"), dtype=np_module.float32)
    strength = rgba[:, :, 3] / 255.0
    output = np_module.zeros((MASK_HEIGHT, MASK_WIDTH), dtype=np_module.float32)
    for output_y in range(MASK_HEIGHT):
        y0 = output_y * SOURCE_HEIGHT // MASK_HEIGHT
        y1 = (output_y + 1) * SOURCE_HEIGHT // MASK_HEIGHT
        for output_x in range(MASK_WIDTH):
            x0 = output_x * SOURCE_WIDTH // MASK_WIDTH
            x1 = (output_x + 1) * SOURCE_WIDTH // MASK_WIDTH
            output[output_y, output_x] = strength[y0:y1, x0:x1].mean()
    return output


@dataclass
class Sample:
    mask: object
    label: list[int]
    digest: str

    def to_tensor(self):
        import torch

        return torch.from_numpy(self.mask).float().unsqueeze(0)


def load_samples(tsv_path: Path, np_module, image_module) -> list[Sample]:
    samples: list[Sample] = []
    with tsv_path.open(encoding="utf-8") as stream:
        header = next(stream, "")
        if header.rstrip("\n") != "file\tlabel":
            raise ValueError(f"invalid TSV header: {tsv_path}")
        for line_number, raw in enumerate(stream, start=2):
            line = raw.rstrip("\n")
            if not line:
                continue
            fields = line.split("\t")
            if len(fields) != 2:
                raise ValueError(f"invalid TSV row {line_number}: {tsv_path}")
            image_path = Path(fields[0])
            label_text = fields[1]
            if len(label_text) != 5 or not label_text.isascii() or not label_text.isdigit():
                raise ValueError(f"invalid FSSP label at row {line_number}")
            png = image_path.read_bytes()
            samples.append(Sample(
                fssp_full_frame_box_average(png, np_module, image_module),
                [int(char) for char in label_text],
                hashlib.sha256(png).hexdigest(),
            ))
    return samples


def evaluate_torch(model, samples, device, np_module, torch_module, threshold: float):
    model.eval()
    total = len(samples)
    exact = 0
    accepted = 0
    accepted_correct = 0
    correct_digits = 0
    with torch_module.no_grad():
        for sample in samples:
            logits = model(sample.to_tensor().unsqueeze(0).to(device))
            prediction = logits.argmax(dim=-1).cpu().numpy()[0]
            probabilities = torch_module.softmax(logits, dim=-1).cpu().numpy()[0]
            confidence = min(
                float(probabilities[index, prediction[index]]) for index in range(5)
            )
            correct = all(prediction[index] == sample.label[index] for index in range(5))
            correct_digits += sum(
                int(prediction[index] == sample.label[index]) for index in range(5)
            )
            exact += int(correct)
            if confidence >= threshold:
                accepted += 1
                accepted_correct += int(correct)
    return {
        "total": total,
        "string": exact / max(1, total),
        "digit": correct_digits / max(1, total * 5),
        "accepted": accepted,
        "accepted_accuracy": accepted_correct / max(1, accepted),
    }


def evaluate_compiled(model_path: Path, samples, np_module):
    """Evaluate the compiled `.mlmodelc`, never the PyTorch surrogate."""

    try:
        import coremltools as ct
        compiled_type = getattr(ct.models, "CompiledMLModel", None)
        if compiled_type is None:
            raise RuntimeError("coremltools.models.CompiledMLModel is unavailable")
        compiled = compiled_type(str(model_path))
    except Exception as error:
        raise RuntimeError(f"cannot load compiled CoreML model: {error}") from error

    exact = 0
    accepted = 0
    accepted_correct = 0
    for sample in samples:
        try:
            result = compiled.predict({
                "inkMask": np_module.asarray(
                    sample.mask, dtype=np_module.float32
                )[None, None, :, :]
            })
            logits = np_module.asarray(result["digits"], dtype=np_module.float32)
        except Exception as error:
            raise RuntimeError(
                f"compiled CoreML prediction failed for {sample.digest}: {error}"
            ) from error
        if logits.shape != (1, 5, 10):
            raise RuntimeError(f"compiled CoreML output shape is {logits.shape}, expected (1, 5, 10)")
        logits = logits[0]
        shifted = logits - logits.max(axis=1, keepdims=True)
        probabilities = np_module.exp(shifted)
        probabilities /= probabilities.sum(axis=1, keepdims=True)
        prediction = logits.argmax(axis=1)
        confidence = min(float(probabilities[index, prediction[index]]) for index in range(5))
        correct = all(prediction[index] == sample.label[index] for index in range(5))
        exact += int(correct)
        if confidence >= 0.98:
            accepted += 1
            accepted_correct += int(correct)
    return {
        "total": len(samples),
        "string": exact / max(1, len(samples)),
        "accepted": accepted,
        "accepted_accuracy": accepted_correct / max(1, accepted),
    }


def _coremlc_path() -> str:
    candidates = [
        "/Applications/Xcode.app/Contents/Developer/usr/bin/coremlc",
        shutil.which("coremlc"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    raise RuntimeError("Xcode coremlc compiler is unavailable")


def compile_model(model, output_staging: Path, torch_module):
    try:
        import coremltools as ct
    except ModuleNotFoundError as error:
        raise RuntimeError("coremltools 9.0 is missing; run setup script") from error

    model_cpu = model.to("cpu")
    model_cpu.eval()
    example = torch_module.zeros(1, 1, MASK_HEIGHT, MASK_WIDTH)
    traced = torch_module.jit.trace(model_cpu, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="inkMask", shape=(1, 1, MASK_HEIGHT, MASK_WIDTH))],
        outputs=[ct.TensorType(name="digits")],
        minimum_deployment_target=ct.target.macOS12,
    )

    package_path = output_staging.parent / f"{MODEL_NAME}-{uuid.uuid4().hex}.mlpackage"
    compile_parent = output_staging.parent / f"{MODEL_NAME}-{uuid.uuid4().hex}.compiled"
    try:
        mlmodel.save(str(package_path))
        compile_parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            [_coremlc_path(), "compile", str(package_path), str(compile_parent)],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(
                "coremlc compile failed:\n"
                f"stdout: {result.stdout}\nstderr: {result.stderr}"
            )
        candidates = sorted(compile_parent.glob("*.mlmodelc"))
        if len(candidates) != 1:
            raise RuntimeError(f"coremlc output is ambiguous: {candidates}")
        compiled = candidates[0]
        shutil.move(str(compiled), str(output_staging))
        return output_staging
    finally:
        if package_path.exists():
            shutil.rmtree(package_path)
        if compile_parent.exists():
            shutil.rmtree(compile_parent)


def atomic_replace_directory(staged: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    backup = destination.parent / f".{destination.name}.previous-{uuid.uuid4().hex}"
    if destination.exists():
        os.replace(destination, backup)
    try:
        os.replace(staged, destination)
    except Exception:
        if backup.exists() and not destination.exists():
            os.replace(backup, destination)
        raise
    if backup.exists():
        shutil.rmtree(backup)


def atomic_write_json(payload: dict, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.parent / f".{destination.name}.tmp-{uuid.uuid4().hex}"
    try:
        temporary.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            temporary.unlink()


def _prepare_split(corpus: Path, work: Path, regression_tsv: Path | None, minimum: int):
    command = [
        sys.executable,
        str(ROOT / "Scripts" / "prepare-fssp-corpus.py"),
        "--corpus", str(corpus),
        "--train-tsv", str(work / "train.tsv"),
        "--test-tsv", str(work / "held-out.tsv"),
        "--minimum", str(minimum),
    ]
    if regression_tsv:
        command.extend(["--regression-tsv", str(regression_tsv)])
    subprocess.run(command, check=True)
    return work / "train.tsv", work / "held-out.tsv"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--regression-tsv", type=Path)
    parser.add_argument("--epochs", type=int, default=60)
    parser.add_argument("--batch", type=int, default=24)
    parser.add_argument("--lr", type=float, default=0.001)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--device", choices=("cpu", "mps"), default="cpu")
    parser.add_argument("--minimum", type=int, default=200)
    args = parser.parse_args(argv)

    corpus = args.corpus.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()
    regression_tsv = args.regression_tsv.expanduser().resolve() if args.regression_tsv else None
    if regression_tsv is None:
        default_regression = ROOT / "Tests/CaptchaSolverTests/Fixtures/fssp/regression.tsv"
        regression_tsv = default_regression if default_regression.is_file() else None
    work = output_dir / f".fssp-bootstrap-work-{uuid.uuid4().hex}"
    report_path = output_dir / REPORT_NAME
    destination = output_dir / f"{MODEL_NAME}.mlmodelc"
    output_dir.mkdir(parents=True, exist_ok=True)
    try:
        # A failed retrain must not leave an old passing report paired with an
        # unchanged or incomplete corpus. The model may remain as a manual
        # artifact, but the lab is fail-closed without this report.
        if report_path.exists():
            report_path.unlink()
        work.mkdir(parents=True)
        train_tsv, held_out_tsv = _prepare_split(
            corpus, work, regression_tsv, args.minimum
        )
        unique_count = len({
            hashlib.sha256(path.read_bytes()).hexdigest()
            for path in corpus.glob("*.png")
        })
        held_out_count = len(held_out_tsv.read_text(encoding="utf-8").splitlines()) - 1
        if unique_count < 200 or held_out_count < 30:
            raise RuntimeError(
                f"bootstrap gate requires corpus>=200 and held_out>=30; "
                f"got corpus={unique_count}, held_out={held_out_count}"
            )

        np_module, torch_module, image_module, helper = _load_dependencies()
        train = load_samples(train_tsv, np_module, image_module)
        held_out = load_samples(held_out_tsv, np_module, image_module)
        if not train or not held_out:
            raise RuntimeError("prepared train or held-out split is empty")

        torch_module.manual_seed(args.seed)
        np_module.random.seed(args.seed)
        device_name = args.device
        if device_name == "mps" and not torch_module.backends.mps.is_available():
            print("MPS unavailable; falling back to CPU")
            device_name = "cpu"
        device = torch_module.device(device_name)
        model = helper.CaptchaNet().to(device)
        optimizer = torch_module.optim.Adam(
            model.parameters(), lr=args.lr, weight_decay=1e-4
        )
        best_score = (-1.0, -1.0)
        best_state = None
        for epoch in range(1, args.epochs + 1):
            loss = helper.train_epoch(model, optimizer, train, args.batch, device)
            metrics = evaluate_torch(model, held_out, device, np_module, torch_module, 0.98)
            print(
                f"epoch {epoch:2d} loss={loss:.4f} "
                f"held-out-exact={metrics['string']:.3f} "
                f"held-out-digit={metrics['digit']:.3f} "
                f"accepted@.98={metrics['accepted']}"
            )
            score = (metrics["string"], metrics["digit"])
            if score > best_score:
                best_score = score
                best_state = {
                    key: value.detach().cpu().clone()
                    for key, value in model.state_dict().items()
                }
        if best_state is None:
            raise RuntimeError("training produced no model state")
        model.load_state_dict(best_state)

        stage_root = work / "compiled"
        stage_root.mkdir(parents=True)
        staged_model = stage_root / f"{MODEL_NAME}.mlmodelc"
        compile_model(model, staged_model, torch_module)
        # The report is based exclusively on the compiled CoreML outputs.
        final_metrics = evaluate_compiled(staged_model, held_out, np_module)
        print(
            f"compiled held-out-exact={final_metrics['string']:.3f} "
            f"accepted@.98={final_metrics['accepted']} "
            f"accepted-accuracy={final_metrics['accepted_accuracy']:.3f}"
        )

        report = {
            "version": 1,
            "modelName": MODEL_NAME,
            "split": SPLIT_NAME,
            "uniqueCorpusCount": unique_count,
            "heldOutCount": final_metrics["total"],
            "heldOutStringAccuracy": final_metrics["string"],
            "acceptedAt098Count": final_metrics["accepted"],
            "acceptedAt098Accuracy": final_metrics["accepted_accuracy"],
            "trainedAt": datetime.now(timezone.utc)
                .replace(microsecond=0)
                .isoformat()
                .replace("+00:00", "Z"),
            "preprocessorVersion": PREPROCESSOR_VERSION,
        }
        atomic_replace_directory(staged_model, destination)
        atomic_write_json(report, report_path)
        print(f"model={destination}")
        print(f"report={report_path}")
        return 0
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"FSSP bootstrap training failed: {error}", file=sys.stderr)
        return 1
    finally:
        if work.exists():
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
