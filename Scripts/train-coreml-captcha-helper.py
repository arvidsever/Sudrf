#!/usr/bin/env python3
"""
Scripts/train-coreml-captcha-helper.py

Обучает CoreML-модель для распознавания 5-значных sudrf captcha и
компилирует её в `.mlmodelc/`. Архитектура — по описанию друга в
`Docs/branch-changelogs/captcha-auto-solver/v0.38.8.md`:

  вход 100×30 RGB → бинарная маска «чернил» (порог по RGB-расстоянию
  от судрфовского teal ~(2, 103, 154)) → downsample 100×30 → 64×20
  (box-averaging) → PyTorch:
    conv 3×3, 8 фильтров, leakyReLU, maxpool 2×2
    conv 3×3, 16 фильтров, leakyReLU, maxpool 2×2
    dense 64, leakyReLU
    5 × softmax(10)  (5 позиций × 10 цифр)

Запуск:

  source ~/.venvs/sudrf-train/bin/activate
  python3 Scripts/train-coreml-captcha-helper.py \\
    --train-tsv /tmp/train-data.tsv \\
    --test-tsv  /tmp/test-data.tsv \\
    --output    Tests/CaptchaSolverTests/Fixtures/model-captcha-numeric.mlmodelc/ \\
    --epochs 30 --batch 24 --lr 0.02

Зависимости:
  Scripts/setup-fssp-bootstrap.sh (фиксирует coremltools 9.0, torch 2.7.0,
  numpy 1.26.4 и Pillow 11.3.0)

После завершения файл `model-captcha-numeric.mlmodelc/` будет лежать
в `Tests/CaptchaSolverTests/Fixtures/`. `swift test` подхватит его
через `Bundle.module` → `CoreMLModelDiscovery.discoverURL()`.
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from io import BytesIO
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image

# Целевые значения RGB судрфовского teal (для binarize).
INK_R, INK_G, INK_B = 2, 103, 154
INK_THRESH_SQ = 80 * 80  # squared RGB distance

INPUT_W, INPUT_H = 100, 30
MASK_W, MASK_H = 64, 20
FSSP_INPUT_W, FSSP_INPUT_H = 240, 80


def binarize_and_downsample(png_bytes: bytes) -> np.ndarray:
    """100×30 RGB → 64×20 float mask, значения ∈ [0, 1]."""
    img = Image.open(BytesIO(png_bytes)).convert("RGB").resize(
        (INPUT_W, INPUT_H), Image.BILINEAR
    )
    arr = np.array(img, dtype=np.float32)
    dr = arr[..., 0] - INK_R
    dg = arr[..., 1] - INK_G
    db = arr[..., 2] - INK_B
    mask100 = (dr * dr + dg * dg + db * db) < INK_THRESH_SQ
    # Box-average downsample 100×30 → 64×20.
    out = np.zeros((MASK_H, MASK_W), dtype=np.float32)
    for oy in range(MASK_H):
        y0, y1 = oy * INPUT_H // MASK_H, (oy + 1) * INPUT_H // MASK_H
        for ox in range(MASK_W):
            x0, x1 = ox * INPUT_W // MASK_W, (ox + 1) * INPUT_W // MASK_W
            out[oy, ox] = mask100[y0:y1, x0:x1].mean()
    return out


def fssp_full_frame_box_average(png_bytes: bytes) -> np.ndarray:
    """240x80 RGB -> 64x20 max(R,G,B)/255 box average."""
    img = Image.open(BytesIO(png_bytes)).convert("RGB")
    if img.size != (FSSP_INPUT_W, FSSP_INPUT_H):
        raise ValueError(
            f"FSSP CAPTCHA must be 240x80, got {img.width}x{img.height}"
        )
    arr = np.asarray(img, dtype=np.float32)
    strength = arr.max(axis=2) / 255.0
    out = np.zeros((MASK_H, MASK_W), dtype=np.float32)
    for oy in range(MASK_H):
        y0, y1 = oy * FSSP_INPUT_H // MASK_H, (oy + 1) * FSSP_INPUT_H // MASK_H
        for ox in range(MASK_W):
            x0, x1 = ox * FSSP_INPUT_W // MASK_W, (ox + 1) * FSSP_INPUT_W // MASK_W
            out[oy, ox] = strength[y0:y1, x0:x1].mean()
    return out


class CaptchaSample:
    """Один captcha после binarize: маска + 5-цифровая метка."""
    __slots__ = ("mask", "label", "digest")

    def __init__(self, mask: np.ndarray, label: list[int], digest: str):
        self.mask = mask  # (20, 64) float32 ∈ [0, 1]
        self.label = label  # length-5 list of int in 0..9
        self.digest = digest

    def to_tensor(self) -> torch.Tensor:
        # (1, 20, 64) — one sample, one channel. `train_epoch` stacks
        # these into a batch (B, 1, 20, 64).
        return torch.from_numpy(self.mask).float().unsqueeze(0)


def load_corpus(tsv_path: Path, preprocessor=binarize_and_downsample) -> list[CaptchaSample]:
    """Читает TSV формата `<file>\t<5digits>` (см. train-coreml-captcha.swift)."""
    samples: list[CaptchaSample] = []
    skipped = 0
    with open(tsv_path) as f:
        next(f)  # header
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != 2:
                skipped += 1
                continue
            path_str, label_str = parts
            if len(label_str) != 5 or not label_str.isdigit():
                skipped += 1
                continue
            try:
                with open(path_str, "rb") as fp:
                    png = fp.read()
                    mask = preprocessor(png)
            except Exception as e:
                print(f"  skip {path_str}: {e}", file=sys.stderr)
                skipped += 1
                continue
            samples.append(CaptchaSample(
                mask, [int(c) for c in label_str], hashlib.sha256(png).hexdigest()
            ))
    print(f"loaded {len(samples)} samples from {tsv_path.name} (skipped {skipped})")
    return samples


class CaptchaNet(nn.Module):
    """Архитектура по friend's MD. NCHW input: (B, 1, 20, 64)."""
    def __init__(self):
        super().__init__()
        # 20×64 → conv 3×3 (padding 1) → leakyReLU → 20×64
        self.conv1 = nn.Conv2d(1, 8, kernel_size=3, padding=1)
        # maxpool 2×2 → 10×32
        # conv 3×3 → leakyReLU → 10×32
        self.conv2 = nn.Conv2d(8, 16, kernel_size=3, padding=1)
        # maxpool 2×2 → 5×16
        self.fc = nn.Linear(16 * 5 * 16, 64)
        # 5 heads × 10 classes (digits 0-9).
        self.heads = nn.ModuleList([nn.Linear(64, 10) for _ in range(5)])

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = F.leaky_relu(self.conv1(x), negative_slope=0.01)
        x = F.max_pool2d(x, 2)
        x = F.leaky_relu(self.conv2(x), negative_slope=0.01)
        x = F.max_pool2d(x, 2)
        x = x.flatten(1)
        x = F.leaky_relu(self.fc(x), negative_slope=0.01)
        # Stack 5 heads: output shape (B, 5, 10).
        return torch.stack([h(x) for h in self.heads], dim=1)


def train_epoch(model: CaptchaNet,
                opt: torch.optim.Optimizer,
                samples: list[CaptchaSample],
                batch_size: int,
                device: torch.device) -> float:
    model.train()
    # Shuffle once per epoch.
    perm = np.random.permutation(len(samples))
    total_loss = 0.0
    n_batches = 0
    for i in range(0, len(samples), batch_size):
        batch_idx = perm[i:i + batch_size]
        batch = [samples[j] for j in batch_idx]
        # Build batched tensors.
        x = torch.stack([s.to_tensor() for s in batch]).to(device)
        y = torch.tensor([s.label for s in batch], dtype=torch.long, device=device)
        # (B, 5, 10) logits.
        logits = model(x)
        # 5-head cross-entropy: per-position CE, summed.
        loss = sum(F.cross_entropy(logits[:, k], y[:, k]) for k in range(5))
        opt.zero_grad()
        loss.backward()
        opt.step()
        total_loss += float(loss.item())
        n_batches += 1
    return total_loss / max(1, n_batches)


@torch.no_grad()
def evaluate(model: CaptchaNet,
             samples: list[CaptchaSample],
             device: torch.device) -> dict:
    """Per-digit accuracy + per-string (all 5 correct) accuracy."""
    model.eval()
    correct_per_digit = np.zeros(5, dtype=np.int64)
    total = 0
    correct_string = 0
    accepted_at_090 = 0
    accepted_correct_at_090 = 0
    for s in samples:
        x = s.to_tensor().unsqueeze(0).to(device)
        y = np.array(s.label, dtype=np.int64)
        logits = model(x)  # (1, 5, 10)
        pred = logits.argmax(dim=-1).cpu().numpy()[0]  # (5,)
        probs = torch.softmax(logits, dim=-1).cpu().numpy()[0]
        confidence = float(min(probs[k, pred[k]] for k in range(5)))
        for k in range(5):
            if pred[k] == y[k]:
                correct_per_digit[k] += 1
        if np.array_equal(pred, y):
            correct_string += 1
            if confidence >= 0.90:
                accepted_correct_at_090 += 1
        if confidence >= 0.90:
            accepted_at_090 += 1
        total += 1
    return {
        "per_digit": (correct_per_digit / max(1, total)).tolist(),
        "string": correct_string / max(1, total),
        "total": total,
        "accepted_at_090": accepted_at_090,
        "accepted_accuracy_at_090": (
            accepted_correct_at_090 / accepted_at_090 if accepted_at_090 else 0.0
        ),
    }


def evaluate_compiled(model_path: Path,
                      samples: list[CaptchaSample],
                      threshold: float = 0.90) -> dict:
    """Evaluate the compiled CoreML artifact, not its PyTorch source."""
    import coremltools as ct

    compiled_type = getattr(ct.models, "CompiledMLModel", None)
    if compiled_type is None:
        raise RuntimeError("coremltools.models.CompiledMLModel is unavailable")
    compiled = compiled_type(str(model_path))
    correct_string = 0
    accepted = 0
    accepted_correct = 0
    for sample in samples:
        result = compiled.predict({
            "inkMask": np.asarray(sample.mask, dtype=np.float32)[None, None, :, :]
        })
        logits = np.asarray(result["digits"], dtype=np.float32)
        if logits.shape != (1, 5, 10):
            raise RuntimeError(
                f"compiled CoreML output shape is {logits.shape}, expected (1, 5, 10)"
            )
        logits = logits[0]
        shifted = logits - logits.max(axis=1, keepdims=True)
        probabilities = np.exp(shifted)
        probabilities /= probabilities.sum(axis=1, keepdims=True)
        prediction = logits.argmax(axis=1)
        confidence = min(float(probabilities[index, prediction[index]]) for index in range(5))
        correct = bool(np.array_equal(prediction, np.asarray(sample.label)))
        correct_string += int(correct)
        if confidence >= threshold:
            accepted += 1
            accepted_correct += int(correct)
    total = len(samples)
    return {
        "per_digit": [],
        "string": correct_string / max(1, total),
        "total": total,
        "accepted_at_090": accepted,
        "accepted_accuracy_at_090": accepted_correct / max(1, accepted),
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--train-tsv", required=True, type=Path)
    p.add_argument("--test-tsv", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path,
                   help="path to .mlmodelc/ dir (will be created)")
    p.add_argument("--epochs", type=int, default=30)
    p.add_argument("--batch", type=int, default=24)
    p.add_argument("--lr", type=float, default=0.02)
    p.add_argument("--milestones", type=int, nargs="+", default=[10, 16, 22],
                   help="epoch numbers at which to multiply lr by 0.5")
    p.add_argument("--momentum", type=float, default=0.9)
    p.add_argument("--weight-decay", type=float, default=1e-4)
    p.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--eligibility-output", type=Path,
                   help="write FSSP eligibility JSON only when every gate passes")
    p.add_argument("--regression-tsv", type=Path,
                   help="manually verified FSSP regression fixtures")
    p.add_argument("--model-name", default="model-captcha-numeric")
    args = p.parse_args()

    # A failed retrain must never inherit a previously passing runtime gate.
    if args.eligibility_output and args.eligibility_output.exists():
        args.eligibility_output.unlink()

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)

    if args.device == "mps" and not torch.backends.mps.is_available():
        print("MPS not available, falling back to CPU")
        args.device = "cpu"
    device = torch.device(args.device)
    print(f"device: {device}")

    # 1) Load corpus.
    preprocessor = (
        fssp_full_frame_box_average
        if args.model_name == "model-captcha-fssp"
        else binarize_and_downsample
    )
    train = load_corpus(args.train_tsv, preprocessor=preprocessor)
    test = load_corpus(args.test_tsv, preprocessor=preprocessor)
    if not train or not test:
        print("error: empty corpus (run train-coreml-captcha.swift first)", file=sys.stderr)
        sys.exit(1)
    regression: list[CaptchaSample] = []
    if args.eligibility_output:
        if args.model_name != "model-captcha-fssp":
            print("error: FSSP eligibility requires --model-name model-captcha-fssp", file=sys.stderr)
            sys.exit(1)
        if args.output.name != "model-captcha-fssp.mlmodelc":
            print("error: FSSP output must be model-captcha-fssp.mlmodelc", file=sys.stderr)
            sys.exit(1)
        if not args.regression_tsv:
            print("error: --regression-tsv required for FSSP eligibility", file=sys.stderr)
            sys.exit(1)
        regression = load_corpus(args.regression_tsv, preprocessor=preprocessor)
        train_hashes = {sample.digest for sample in train}
        test_hashes = {sample.digest for sample in test}
        if train_hashes & test_hashes:
            print("error: duplicate SHA-256 across train and held-out sets", file=sys.stderr)
            sys.exit(1)
        if len(train_hashes | test_hashes) < 2_000:
            print("error: FSSP corpus has fewer than 2000 unique images", file=sys.stderr)
            sys.exit(1)
        if len({sample.digest for sample in regression}) < 30:
            print("error: FSSP regression set has fewer than 30 unique fixtures", file=sys.stderr)
            sys.exit(1)

    # 2) Train.
    model = CaptchaNet().to(device)
    opt = torch.optim.SGD(model.parameters(), lr=args.lr,
                          momentum=args.momentum,
                          weight_decay=args.weight_decay)
    sched = torch.optim.lr_scheduler.MultiStepLR(
        opt, milestones=args.milestones, gamma=0.5
    )
    print(f"model params: {sum(p.numel() for p in model.parameters())}")
    best_score = 0.0
    best_state = None
    for epoch in range(1, args.epochs + 1):
        t0 = time.time()
        loss = train_epoch(model, opt, train, args.batch, device)
        sched.step()
        eval_train = evaluate(model, train, device)
        eval_test = evaluate(model, test, device)
        per_digit_mean = float(np.mean(eval_test["per_digit"]))
        per_string = eval_test["string"]
        elapsed = time.time() - t0
        print(
            f"epoch {epoch:2d} | loss {loss:.4f} | "
            f"train per-digit {np.mean(eval_train['per_digit']):.3f} | "
            f"test per-digit {per_digit_mean:.3f} | "
            f"test per-string {per_string:.3f} | "
            f"lr {opt.param_groups[0]['lr']:.4f} | {elapsed:.1f}s"
        )
        selection_score = per_string if args.eligibility_output else per_digit_mean
        if selection_score > best_score:
            best_score = selection_score
            best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}

    if best_state is None:
        print("error: training produced no improvement", file=sys.stderr)
        sys.exit(1)
    model.load_state_dict(best_state)
    print(f"best selection score: {best_score:.3f}")

    # 3) Convert to CoreML.
    print("converting to CoreML...")
    import coremltools as ct
    # Move model to CPU for tracing — coremltools 9 + torch.jit.trace
    # have device-mismatch issues on MPS. CPU trace is portable to
    # both .mlpackage (later compiled for any target) and runtime.
    model_cpu = CaptchaNet()
    model_cpu.load_state_dict(model.state_dict())
    model_cpu.eval()
    example = torch.zeros(1, 1, MASK_H, MASK_W)
    traced = torch.jit.trace(model_cpu, example)
    # Один выходной тензор (1, 5, 10) — `torch.stack` в forward
    # склеивает 5 голов в один тензор. На стороне Swift
    # `MLMultiArray` имеет shape `[1, 5, 10]` — argmax по оси -1
    # даёт 5 цифр. Имя выхода `digits` — соответствует соглашению
    # с `CoreMLCaptchaStrategy`.
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="inkMask", shape=(1, 1, MASK_H, MASK_W))],
        outputs=[ct.TensorType(name="digits")],
        minimum_deployment_target=ct.target.macOS12,
    )

    # Save as .mlpackage first (coremltools 9 requires this).
    pkg_path = args.output.with_suffix(".mlpackage")
    if pkg_path.exists():
        shutil.rmtree(pkg_path)
    mlmodel.save(str(pkg_path))
    print(f"saved: {pkg_path}")

    # 4) Compile to .mlmodelc/. coremlc создаёт лишний подкаталог
    # `<args.output>/<modelname>.mlmodelc/...` — вытаскиваем
    # содержимое наверх, чтобы Swift `MLModel(contentsOf:)` смотрел
    # на каталог с `coremldata.bin` напрямую.
    if args.output.exists():
        shutil.rmtree(args.output)
    staging = args.output.parent / (args.output.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    coremlc = "/Applications/Xcode.app/Contents/Developer/usr/bin/coremlc"
    result = subprocess.run(
        [coremlc, "compile", str(pkg_path), str(staging)],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print("coremlc compile failed:", file=sys.stderr)
        print("stdout:", result.stdout, file=sys.stderr)
        print("stderr:", result.stderr, file=sys.stderr)
        sys.exit(1)
    # coremlc пишет `staging/<modelname>.mlmodelc/{coremldata.bin,...}`.
    # Поднимаем на уровень выше.
    inner = staging / (pkg_path.stem + ".mlmodelc")
    if not inner.is_dir():
        print(f"coremlc output missing: {inner}", file=sys.stderr)
        sys.exit(1)
    args.output.mkdir(parents=True, exist_ok=True)
    for entry in inner.iterdir():
        shutil.move(str(entry), str(args.output / entry.name))
    shutil.rmtree(staging)
    print(f"compiled: {args.output}")
    print("contents:", sorted(p.name for p in args.output.iterdir()))

    # 5) Cleanup intermediate.
    shutil.rmtree(pkg_path)

    # 6) Print final report.
    # Eligibility must be based on the artifact that Swift will load. The
    # ordinary numeric trainer keeps its historical PyTorch report, while the
    # FSSP release gate fails closed if compiled CoreML cannot be evaluated.
    if args.eligibility_output:
        try:
            final_eval = evaluate_compiled(args.output, test, threshold=0.90)
        except Exception as error:
            print(f"error: compiled CoreML evaluation failed: {error}", file=sys.stderr)
            sys.exit(1)
    else:
        final_eval = evaluate(model, test, device)
    regression_eval = evaluate(model, regression, device) if regression else None
    print()
    print("=== final report ===")
    print(f"per-digit:  {final_eval['per_digit']}")
    print(f"per-string: {final_eval['string']:.3f}  "
          f"({int(final_eval['string'] * final_eval['total'])}/{final_eval['total']})")
    print(f"model:      {args.output}")
    if regression_eval:
        print(f"regression exact: {regression_eval['string']:.3f}  "
              f"({int(regression_eval['string'] * regression_eval['total'])}/{regression_eval['total']})")
    print()
    print("next step: place this .mlmodelc/ in")
    print(f"  {args.output}")
    print("and run `swift test` — CoreMLCaptchaStrategyTests will use it.")

    if args.eligibility_output:
        unique_count = len({sample.digest for sample in train + test})
        accepted_count = final_eval["accepted_at_090"]
        accepted_accuracy = final_eval["accepted_accuracy_at_090"]
        if final_eval["string"] < 0.97:
            print("error: held-out exact-string accuracy is below 0.97", file=sys.stderr)
            sys.exit(1)
        if accepted_count < 100 or accepted_accuracy < 0.99:
            print("error: accepted-answer gate requires at least 100 answers at 0.90 with accuracy >= 0.99", file=sys.stderr)
            sys.exit(1)
        report = {
            "version": 1,
            "modelName": args.model_name,
            "split": "sha256-mod5-v1",
            "uniqueCorpusCount": unique_count,
            "regressionFixtureCount": len({sample.digest for sample in regression}),
            "heldOutStringAccuracy": final_eval["string"],
            "acceptedAt090Count": accepted_count,
            "acceptedAt090Accuracy": accepted_accuracy,
        }
        args.eligibility_output.parent.mkdir(parents=True, exist_ok=True)
        args.eligibility_output.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(f"eligibility: {args.eligibility_output}")


if __name__ == "__main__":
    main()
