#!/usr/bin/env python3
"""Train and atomically publish the lab-only FSSP bootstrap model.

The pipeline has three content-addressed sets. Training sees only SHA buckets
1--4 and 6--9; bucket 5 is validation for checkpoint selection; bucket 0 is
an independent exam evaluated only after the CoreML model has been compiled.
The final report is written only after compiled-CoreML metrics and parity have
passed, so the lab remains fail-closed on conversion or numerical drift.
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
from io import BytesIO
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PREPROCESSOR_VERSION = "fssp-dominant-span-box-v3"
ARCHITECTURE_VERSION = "fssp-shared-cnn-v2"
MODEL_NAME = "model-captcha-fssp-bootstrap"
REPORT_NAME = f"{MODEL_NAME}-report.json"
SPLIT_NAME = "sha256-mod10-v2"
SOURCE_WIDTH, SOURCE_HEIGHT = 240, 80
MASK_WIDTH, MASK_HEIGHT = 64, 20
MAX_EPOCHS = 200
DEFAULT_PATIENCE = 30
AUTO_CONFIDENCE = 0.50
PARITY_TOLERANCE = 0.001
_HELPER_MODULE = None


def _load_helper_module():
    global _HELPER_MODULE
    if _HELPER_MODULE is not None:
        return _HELPER_MODULE
    helper_path = ROOT / "Scripts" / "train-coreml-captcha-helper.py"
    spec = importlib.util.spec_from_file_location("captcha_training_helper", helper_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load training architecture: {helper_path}")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    _HELPER_MODULE = helper
    return helper


def _load_dependencies():
    """Load the pinned ML stack only after split validation."""
    try:
        import numpy as np
        import torch
        from PIL import Image
    except ModuleNotFoundError as error:
        raise RuntimeError(
            "FSSP trainer dependencies are missing; run "
            "Scripts/setup-fssp-bootstrap.sh first"
        ) from error

    return np, torch, Image, _load_helper_module()


def fssp_dominant_span_box_v3(
    png_bytes: bytes,
    np_module=None,
    image_module=None,
) -> object:
    """Use the single v3 implementation shared with the CoreML helper."""
    if np_module is None or image_module is None:
        _load_dependencies()
    return _load_helper_module().fssp_dominant_span_box_v3(png_bytes)


# Compatibility name used by earlier lab diagnostics and hidden script tests.
def fssp_full_frame_box_average(png_bytes: bytes, np_module=None, image_module=None):
    return fssp_dominant_span_box_v3(png_bytes, np_module, image_module)


@dataclass
class Sample:
    mask: object
    label: list[int]
    digest: str

    def to_tensor(self, torch_module):
        return torch_module.from_numpy(self.mask).float().unsqueeze(0)


def load_samples(tsv_path: Path, np_module, image_module) -> list[Sample]:
    """Read ``file<TAB>five digits`` rows and preprocess only those rows."""
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
            mask = fssp_dominant_span_box_v3(png, np_module, image_module)
            samples.append(Sample(
                mask,
                [int(char) for char in label_text],
                hashlib.sha256(png).hexdigest(),
            ))
    return samples


def _unit_float(digest: str, seed: int, epoch: int, index: int) -> float:
    material = f"{seed}:{epoch}:{digest}:{index}".encode("ascii")
    value = int.from_bytes(hashlib.sha256(material).digest()[:8], "big")
    return value / float(1 << 64)


def deterministic_affine_parameters(
    digest: str, seed: int, epoch: int
) -> tuple[float, float, float, float]:
    """Return deterministic angle, scale, x-translation, y-translation."""
    angle = -3.0 + 6.0 * _unit_float(digest, seed, epoch, 0)
    scale = 0.95 + 0.10 * _unit_float(digest, seed, epoch, 1)
    translate_x = -0.04 + 0.08 * _unit_float(digest, seed, epoch, 2)
    translate_y = -0.05 + 0.10 * _unit_float(digest, seed, epoch, 3)
    return angle, scale, translate_x, translate_y


def _augment_sample(sample: Sample, torch_module, device, seed: int, epoch: int):
    import math
    import torch.nn.functional as functional

    tensor = sample.to_tensor(torch_module).to(device)
    angle, scale, tx, ty = deterministic_affine_parameters(sample.digest, seed, epoch)
    radians = math.radians(angle)
    cosine, sine = math.cos(radians), math.sin(radians)
    theta = torch_module.tensor(
        [[
            [scale * cosine, -scale * sine, tx],
            [scale * sine, scale * cosine, ty],
        ]],
        dtype=tensor.dtype,
        device=device,
    )
    grid = functional.affine_grid(
        theta, (1, 1, MASK_HEIGHT, MASK_WIDTH), align_corners=False
    )
    return functional.grid_sample(
        tensor.unsqueeze(0), grid, mode="bilinear", padding_mode="zeros",
        align_corners=False,
    ).squeeze(0)


def _batch_tensor(samples, torch_module, device, *, augment, seed, epoch):
    if augment:
        return torch_module.stack([
            _augment_sample(sample, torch_module, device, seed, epoch)
            for sample in samples
        ])
    return torch_module.stack([
        sample.to_tensor(torch_module).to(device) for sample in samples
    ])


def train_epoch(
    model,
    optimizer,
    samples: list[Sample],
    batch_size: int,
    device,
    torch_module,
    np_module,
    *,
    epoch: int = 0,
    seed: int = 0,
    augment: bool = False,
) -> float:
    model.train()
    permutation = np_module.random.permutation(len(samples))
    total_loss = 0.0
    batches = 0
    import torch.nn.functional as functional

    for start in range(0, len(samples), batch_size):
        batch = [samples[index] for index in permutation[start:start + batch_size]]
        x = _batch_tensor(
            batch, torch_module, device, augment=augment, seed=seed, epoch=epoch
        )
        labels = torch_module.tensor(
            [sample.label for sample in batch], dtype=torch_module.long, device=device
        )
        logits = model(x)
        loss = sum(functional.cross_entropy(logits[:, position], labels[:, position])
                   for position in range(5))
        optimizer.zero_grad()
        loss.backward()
        optimizer.step()
        total_loss += float(loss.item())
        batches += 1
    return total_loss / max(1, batches)


def _torch_logits(model, sample: Sample, device, torch_module):
    model.eval()
    with torch_module.no_grad():
        return model(sample.to_tensor(torch_module).unsqueeze(0).to(device))


def evaluate_torch(model, samples, device, np_module, torch_module, threshold=AUTO_CONFIDENCE):
    """Evaluate a PyTorch checkpoint; used only for validation selection."""
    model.eval()
    total = len(samples)
    exact = 0
    correct_digits = 0
    accepted = 0
    accepted_correct = 0
    with torch_module.no_grad():
        for sample in samples:
            logits = model(sample.to_tensor(torch_module).unsqueeze(0).to(device))
            prediction = logits.argmax(dim=-1).cpu().numpy()[0]
            probabilities = torch_module.softmax(logits, dim=-1).cpu().numpy()[0]
            confidence = min(
                float(probabilities[position, prediction[position]])
                for position in range(5)
            )
            correct = all(prediction[position] == sample.label[position] for position in range(5))
            exact += int(correct)
            correct_digits += sum(
                int(prediction[position] == sample.label[position]) for position in range(5)
            )
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


def _load_compiled(model_path: Path):
    try:
        import coremltools as ct
        compiled_type = getattr(ct.models, "CompiledMLModel", None)
        if compiled_type is None:
            raise RuntimeError("coremltools.models.CompiledMLModel is unavailable")
        return compiled_type(str(model_path))
    except Exception as error:
        raise RuntimeError(f"cannot load compiled CoreML model: {error}") from error


def _compiled_logits(compiled, sample: Sample, np_module):
    try:
        result = compiled.predict({
            "inkMask": np_module.asarray(sample.mask, dtype=np_module.float32)[None, None, :, :]
        })
        logits = np_module.asarray(result["digits"], dtype=np_module.float32)
    except Exception as error:
        raise RuntimeError(
            f"compiled CoreML prediction failed for {sample.digest}: {error}"
        ) from error
    if logits.shape != (1, 5, 10):
        raise RuntimeError(
            f"compiled CoreML output shape is {logits.shape}, expected (1, 5, 10)"
        )
    return logits[0]


def evaluate_compiled(
    model_path: Path,
    samples,
    np_module,
    threshold: float = AUTO_CONFIDENCE,
    compiled=None,
):
    """Evaluate the compiled `.mlmodelc`, never the PyTorch surrogate."""
    compiled = compiled or _load_compiled(model_path)
    total = len(samples)
    exact = 0
    correct_digits = 0
    accepted = 0
    accepted_correct = 0
    for sample in samples:
        logits = _compiled_logits(compiled, sample, np_module)
        shifted = logits - logits.max(axis=1, keepdims=True)
        probabilities = np_module.exp(shifted)
        probabilities /= probabilities.sum(axis=1, keepdims=True)
        prediction = logits.argmax(axis=1)
        correct = bool(np_module.array_equal(prediction, np_module.asarray(sample.label)))
        exact += int(correct)
        correct_digits += sum(
            int(prediction[position] == sample.label[position]) for position in range(5)
        )
        confidence = min(
            float(probabilities[position, prediction[position]]) for position in range(5)
        )
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


def check_coreml_parity(
    model,
    model_path: Path,
    samples,
    device,
    np_module,
    torch_module,
    tolerance: float = PARITY_TOLERANCE,
) -> float:
    """Fail closed if CoreML changes a logit beyond tolerance or argmax."""
    if not samples:
        raise RuntimeError("CoreML parity set is empty")
    compiled = _load_compiled(model_path)
    max_difference = 0.0
    model_cpu = model.to("cpu")
    model_cpu.eval()
    for sample in samples:
        with torch_module.no_grad():
            expected = model_cpu(sample.to_tensor(torch_module).unsqueeze(0)).cpu().numpy()[0]
        actual = _compiled_logits(compiled, sample, np_module)
        difference = float(np_module.max(np_module.abs(expected - actual)))
        max_difference = max(max_difference, difference)
        if not np_module.array_equal(expected.argmax(axis=1), actual.argmax(axis=1)):
            raise RuntimeError(f"CoreML argmax parity failed for {sample.digest}")
        if difference > tolerance:
            raise RuntimeError(
                f"CoreML logit parity failed for {sample.digest}: "
                f"max difference {difference:.6f} > {tolerance:.6f}"
            )
    return max_difference


def _coremlc_path() -> str:
    candidates = [
        "/Applications/Xcode.app/Contents/Developer/usr/bin/coremlc",
        "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/coremlc",
        shutil.which("coremlc"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    raise RuntimeError("Xcode coremlc compiler is unavailable")


def compile_model(model, output_staging: Path, torch_module):
    try:
        import coremltools as ct
        import numpy as np
    except ModuleNotFoundError as error:
        raise RuntimeError("coremltools 9.0 is missing; run setup script") from error

    model_cpu = model.to("cpu")
    model_cpu.eval()
    example = torch_module.zeros(1, 1, MASK_HEIGHT, MASK_WIDTH, dtype=torch_module.float32)
    traced = torch_module.jit.trace(model_cpu, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(
            name="inkMask", shape=(1, 1, MASK_HEIGHT, MASK_WIDTH), dtype=np.float32
        )],
        outputs=[ct.TensorType(name="digits", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS12,
        compute_precision=ct.precision.FLOAT32,
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
        if output_staging.exists():
            shutil.rmtree(output_staging)
        shutil.move(str(candidates[0]), str(output_staging))
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
        "--validation-tsv", str(work / "validation.tsv"),
        "--exam-tsv", str(work / "exam.tsv"),
        "--minimum", str(minimum),
    ]
    if regression_tsv:
        command.extend(["--regression-tsv", str(regression_tsv)])
    subprocess.run(command, check=True)
    return work / "train.tsv", work / "validation.tsv", work / "exam.tsv"


def _report_metrics(metrics: dict) -> tuple[float, float]:
    return metrics["string"], metrics["digit"]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--regression-tsv", type=Path)
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
    if args.patience < 1:
        parser.error("--patience must be positive")
    if args.batch < 1:
        parser.error("--batch must be positive")

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
        # Any old v1 report is invalid. Keeping a stale report would allow the
        # Swift lab to mistake it for a result from the current preprocessing.
        if report_path.exists():
            report_path.unlink()
        work.mkdir(parents=True)
        train_tsv, validation_tsv, exam_tsv = _prepare_split(
            corpus, work, regression_tsv, args.minimum
        )
        unique_count = len({
            hashlib.sha256(path.read_bytes()).hexdigest()
            for path in corpus.glob("*.png")
        })
        train_count = len(train_tsv.read_text(encoding="utf-8").splitlines()) - 1
        validation_count = len(validation_tsv.read_text(encoding="utf-8").splitlines()) - 1
        exam_count = len(exam_tsv.read_text(encoding="utf-8").splitlines()) - 1
        if unique_count < 200 or train_count < 1 or validation_count < 1 or exam_count < 1:
            raise RuntimeError(
                "bootstrap gate requires corpus>=200 and non-empty train/validation/exam; "
                f"got corpus={unique_count}, train={train_count}, "
                f"validation={validation_count}, exam={exam_count}"
            )

        np_module, torch_module, image_module, helper = _load_dependencies()
        train = load_samples(train_tsv, np_module, image_module)
        validation = load_samples(validation_tsv, np_module, image_module)
        # The exam is intentionally not decoded before checkpoint selection.
        # Its rows are validated above; image decoding starts after CoreML is
        # compiled and the selected checkpoint is fixed.
        if not train or not validation:
            raise RuntimeError("prepared train or validation split is empty")

        torch_module.manual_seed(args.seed)
        np_module.random.seed(args.seed)
        device_name = args.device
        if device_name == "mps" and not torch_module.backends.mps.is_available():
            print("MPS unavailable; falling back to CPU")
            device_name = "cpu"
        device = torch_module.device(device_name)
        model = helper.FSSPSharedCaptchaNet().to(device)
        optimizer = torch_module.optim.Adam(
            model.parameters(), lr=args.lr, weight_decay=1e-4
        )
        best_score = (-1.0, -1.0)
        best_state = None
        best_epoch = 0
        stale_epochs = 0
        for epoch in range(1, args.epochs + 1):
            loss = train_epoch(
                model, optimizer, train, args.batch, device, torch_module, np_module,
                epoch=epoch, seed=args.seed, augment=True,
            )
            validation_metrics = evaluate_torch(
                model, validation, device, np_module, torch_module
            )
            score = _report_metrics(validation_metrics)
            print(
                f"epoch {epoch:3d} loss={loss:.4f} "
                f"validation-exact={score[0]:.3f} "
                f"validation-digit={score[1]:.3f} "
                f"accepted@.50={validation_metrics['accepted']}"
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
            raise RuntimeError("training produced no model checkpoint")
        model.load_state_dict(best_state)
        print(f"best validation checkpoint: epoch {best_epoch}")

        stage_root = work / "compiled"
        stage_root.mkdir(parents=True)
        staged_model = stage_root / f"{MODEL_NAME}.mlmodelc"
        compile_model(model, staged_model, torch_module)

        # The independent exam is first touched after compilation and parity
        # uses the fixed checkpoint, never a live training epoch.
        exam = load_samples(exam_tsv, np_module, image_module)
        if not exam:
            raise RuntimeError("prepared exam split is empty")
        parity_max_difference = check_coreml_parity(
            model,
            staged_model,
            train + validation + exam,
            device,
            np_module,
            torch_module,
        )
        compiled = _load_compiled(staged_model)
        train_metrics = evaluate_compiled(
            staged_model, train, np_module, threshold=AUTO_CONFIDENCE, compiled=compiled
        )
        validation_metrics = evaluate_compiled(
            staged_model, validation, np_module, threshold=AUTO_CONFIDENCE, compiled=compiled
        )
        exam_metrics = evaluate_compiled(
            staged_model, exam, np_module, threshold=AUTO_CONFIDENCE, compiled=compiled
        )
        print(
            f"compiled exam-exact={exam_metrics['string']:.3f} "
            f"exam-digit={exam_metrics['digit']:.3f} "
            f"accepted@.50={exam_metrics['accepted']} "
            f"accepted-accuracy={exam_metrics['accepted_accuracy']:.3f}"
        )

        report = {
            "version": 2,
            "modelName": MODEL_NAME,
            "split": SPLIT_NAME,
            "uniqueCorpusCount": unique_count,
            "trainCount": train_metrics["total"],
            "trainStringAccuracy": train_metrics["string"],
            "trainDigitAccuracy": train_metrics["digit"],
            "validationCount": validation_metrics["total"],
            "validationStringAccuracy": validation_metrics["string"],
            "validationDigitAccuracy": validation_metrics["digit"],
            "examCount": exam_metrics["total"],
            "examStringAccuracy": exam_metrics["string"],
            "examDigitAccuracy": exam_metrics["digit"],
            "acceptedAt050Count": exam_metrics["accepted"],
            "acceptedAt050Accuracy": exam_metrics["accepted_accuracy"],
            "trainedAt": datetime.now(timezone.utc)
                .replace(microsecond=0)
                .isoformat()
                .replace("+00:00", "Z"),
            "preprocessorVersion": PREPROCESSOR_VERSION,
            "architectureVersion": ARCHITECTURE_VERSION,
            "coreMLParityPassed": True,
            "coreMLMaxLogitDifference": parity_max_difference,
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
