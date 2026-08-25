#!/usr/bin/env python3
"""Review disputed numeric SUDRF CAPTCHA labels without changing sources."""

from __future__ import annotations

import argparse
import base64
import hashlib
import html
import importlib.util
import json
import os
import shutil
import sys
import uuid
import webbrowser
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[1]
STATE_VERSION = 1


@dataclass(frozen=True)
class CorpusEntry:
    digest: str
    path: Path
    label: str
    trusted: bool


@dataclass(frozen=True)
class Prediction:
    value: str
    confidence: float


def valid_label(value: str) -> bool:
    return len(value) == 5 and value.isascii() and value.isdigit()


def label_from_name(path: Path) -> str:
    label = path.name.split("_", 1)[0]
    if not valid_label(label):
        raise ValueError(f"invalid five-digit label: {path.name}")
    return label


def scan_corpora(untrusted: list[Path], trusted: list[Path]) -> dict[str, CorpusEntry]:
    entries: dict[str, CorpusEntry] = {}
    for source, is_trusted in [
        *((path, False) for path in untrusted),
        *((path, True) for path in trusted),
    ]:
        if not source.is_dir():
            continue
        for path in sorted(source.glob("*.png")):
            label = label_from_name(path)
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            candidate = CorpusEntry(digest, path.resolve(), label, is_trusted)
            previous = entries.get(digest)
            if previous is None:
                entries[digest] = candidate
            elif previous.label == label:
                if is_trusted and not previous.trusted:
                    entries[digest] = candidate
            elif is_trusted and not previous.trusted:
                entries[digest] = candidate
            elif previous.trusted and not is_trusted:
                continue
            else:
                raise ValueError(f"conflicting labels for SHA-256 {digest}")
    return entries


def load_state(path: Path) -> dict:
    if not path.is_file():
        return {"version": STATE_VERSION, "decisions": {}}
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("version") != STATE_VERSION or not isinstance(payload.get("decisions"), dict):
        raise ValueError(f"unsupported curation state: {path}")
    return payload


def save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.tmp-{uuid.uuid4().hex}"
    try:
        temporary.write_text(
            json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def _load_training_helper():
    path = ROOT / "Scripts" / "train-coreml-captcha-helper.py"
    spec = importlib.util.spec_from_file_location("captcha_training_helper", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load preprocessor: {path}")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    return helper


def model_fingerprint(model_path: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(item for item in model_path.rglob("*") if item.is_file()):
        digest.update(str(path.relative_to(model_path)).encode("utf-8"))
        digest.update(path.read_bytes())
    return digest.hexdigest()


def cached_predictions(state: dict, fingerprint: str) -> dict[str, Prediction]:
    if state.get("modelFingerprint") != fingerprint:
        return {}
    cached = state.get("predictions", {})
    return {
        digest: Prediction(value["value"], float(value["confidence"]))
        for digest, value in cached.items()
        if isinstance(value, dict)
        and valid_label(value.get("value", ""))
        and isinstance(value.get("confidence"), (int, float))
    }


def predict(
    entries: dict[str, CorpusEntry],
    model_path: Path,
    cached: dict[str, Prediction] | None = None,
) -> dict[str, Prediction]:
    try:
        import coremltools as ct
        import numpy as np
    except ModuleNotFoundError as error:
        raise RuntimeError("trainer environment is missing; run setup-fssp-bootstrap.sh") from error
    if not model_path.is_dir():
        raise RuntimeError(f"numeric CoreML model is missing: {model_path}")
    compiled_type = getattr(ct.models, "CompiledMLModel", None)
    if compiled_type is None:
        raise RuntimeError("coremltools CompiledMLModel is unavailable")
    model = compiled_type(str(model_path))
    helper = _load_training_helper()
    predictions = dict(cached or {})
    missing = [entry for digest, entry in entries.items() if digest not in predictions]
    total = len(missing)
    if not missing:
        print("Предложения модели загружены из кэша", flush=True)
        return {digest: predictions[digest] for digest in entries}
    for index, entry in enumerate(missing, start=1):
        mask = helper.binarize_and_downsample(entry.path.read_bytes())
        result = model.predict({"inkMask": np.asarray(mask, dtype=np.float32)[None, None]})
        logits = np.asarray(result["digits"], dtype=np.float32)[0]
        shifted = logits - logits.max(axis=1, keepdims=True)
        probabilities = np.exp(shifted)
        probabilities /= probabilities.sum(axis=1, keepdims=True)
        digits = logits.argmax(axis=1)
        value = "".join(str(int(digit)) for digit in digits)
        confidence = min(float(probabilities[position, digits[position]]) for position in range(5))
        predictions[entry.digest] = Prediction(value, confidence)
        if index % 500 == 0 or index == total:
            print(f"Распознано {index}/{total}", flush=True)
    return {digest: predictions[digest] for digest in entries}


def review_digests(
    entries: dict[str, CorpusEntry], predictions: dict[str, Prediction], state: dict
) -> list[str]:
    decisions = state["decisions"]
    disputed = [
        digest for digest, entry in entries.items()
        if not entry.trusted
        and predictions[digest].value != entry.label
        and digest not in decisions
    ]
    return sorted(disputed, key=lambda digest: predictions[digest].confidence, reverse=True)


def export_curated(
    entries: dict[str, CorpusEntry],
    predictions: dict[str, Prediction],
    state: dict,
    destination: Path,
) -> dict:
    decisions = state["decisions"]
    staging = destination.parent / f".{destination.name}.staging-{uuid.uuid4().hex}"
    backup = destination.parent / f".{destination.name}.previous-{uuid.uuid4().hex}"
    staging.mkdir(parents=True, exist_ok=False)
    counts = {
        "uniqueSourceCount": len(entries),
        "serverConfirmedCount": 0,
        "modelAgreedCount": 0,
        "manuallyConfirmedCount": 0,
        "excludedCount": 0,
        "unresolvedCount": 0,
        "exportedCount": 0,
    }
    try:
        for digest, entry in entries.items():
            decision = decisions.get(digest)
            label = None
            if entry.trusted:
                counts["serverConfirmedCount"] += 1
                label = entry.label
            elif decision and decision.get("status") == "confirmed":
                candidate = decision.get("confirmedLabel", "")
                if not valid_label(candidate):
                    raise ValueError(f"invalid confirmed label for {digest}")
                counts["manuallyConfirmedCount"] += 1
                label = candidate
            elif decision and decision.get("status") == "excluded":
                counts["excludedCount"] += 1
            elif predictions[digest].value == entry.label:
                counts["modelAgreedCount"] += 1
                label = entry.label
            else:
                counts["unresolvedCount"] += 1
            if label:
                shutil.copy2(entry.path, staging / f"{label}_{digest}.png")
                counts["exportedCount"] += 1
        report = {
            "version": STATE_VERSION,
            "createdAt": datetime.now(timezone.utc)
                .replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            **counts,
        }
        (staging / "curation-report.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            os.replace(destination, backup)
        try:
            os.replace(staging, destination)
        except Exception:
            if backup.exists() and not destination.exists():
                os.replace(backup, destination)
            raise
        if backup.exists():
            shutil.rmtree(backup)
        return report
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def run_web(
    entries: dict[str, CorpusEntry],
    predictions: dict[str, Prediction],
    state: dict,
    state_path: Path,
    destination: Path,
) -> None:
    token = uuid.uuid4().hex
    notice = {"value": ""}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format: str, *_args) -> None:
            pass

        def redirect(self) -> None:
            self.send_response(303)
            self.send_header("Location", f"/{token}/")
            self.end_headers()

        def form(self) -> dict[str, str]:
            length = int(self.headers.get("Content-Length", "0"))
            if length > 4096:
                raise ValueError("request is too large")
            parsed = parse_qs(self.rfile.read(length).decode("utf-8"))
            return {key: values[0] for key, values in parsed.items() if values}

        def do_GET(self) -> None:
            if urlparse(self.path).path != f"/{token}/":
                self.send_error(404)
                return
            queue = review_digests(entries, predictions, state)
            reviewed = len(state["decisions"])
            message = html.escape(notice["value"])
            notice["value"] = ""
            if queue:
                digest = queue[0]
                entry = entries[digest]
                prediction = predictions[digest]
                encoded = base64.b64encode(entry.path.read_bytes()).decode("ascii")
                work = f"""
                  <img src="data:image/png;base64,{encoded}" alt="CAPTCHA">
                  <p class="comparison">Метка файла: <b>{entry.label}</b>
                    <span>Модель: <b>{prediction.value}</b></span></p>
                  <p class="muted">Уверенность модели: {prediction.confidence:.1%}</p>
                  <div class="actions">
                    <form method="post" action="/{token}/decide">
                      <input type="hidden" name="digest" value="{digest}">
                      <button name="choice" value="file">Метка файла верна</button>
                    </form>
                    <form method="post" action="/{token}/decide">
                      <input type="hidden" name="digest" value="{digest}">
                      <button name="choice" value="model">Модель верна</button>
                    </form>
                    <form method="post" action="/{token}/decide">
                      <input type="hidden" name="digest" value="{digest}">
                      <button name="choice" value="exclude">Исключить</button>
                    </form>
                  </div>
                  <form class="custom" method="post" action="/{token}/decide">
                      <input type="hidden" name="digest" value="{digest}">
                      <input name="code" inputmode="numeric" pattern="[0-9]{{5}}"
                        maxlength="5" placeholder="5 цифр" autofocus>
                      <button name="choice" value="custom">Сохранить введённое</button>
                  </form>
                """
            else:
                work = "<h2>Все найденные расхождения разобраны</h2>"
            page = f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
              <meta name="viewport" content="width=device-width,initial-scale=1">
              <title>Проверка CAPTCHA СОЮ</title><style>
              body{{margin:0;background:#f4f4f6;color:#202124;font:16px -apple-system,BlinkMacSystemFont,sans-serif}}
              main{{max-width:900px;margin:32px auto;padding:28px;background:white;border-radius:16px;box-shadow:0 4px 24px #0002}}
              h1{{margin:0 0 6px}} .muted{{color:#666}} .notice{{color:#a44;font-weight:600}}
              img{{display:block;width:min(600px,100%);height:auto;margin:28px auto;image-rendering:pixelated;border:1px solid #ddd}}
              .comparison{{font:22px ui-monospace,monospace;text-align:center}} .comparison span{{margin-left:48px}}
              .actions,.custom{{display:flex;gap:10px;justify-content:center;margin:18px 0;flex-wrap:wrap}}
              button,input{{font:17px -apple-system,BlinkMacSystemFont,sans-serif;padding:10px 16px;border-radius:9px;border:1px solid #bbb}}
              button{{cursor:pointer;background:#f1f1f3}} input{{width:130px;text-align:center;background:white}}
              footer{{margin-top:28px;padding-top:20px;border-top:1px solid #ddd}}
              </style></head><body><main><h1>Проверка разметки CAPTCHA СОЮ</h1>
              <p class="muted">Исходная папка не изменяется. Решение сохраняется сразу.</p>
              <p>Проверено: {reviewed} · осталось расхождений: {len(queue)} · всего уникальных: {len(entries)}</p>
              <p class="notice">{message}</p>{work}<footer>
              <form method="post" action="/{token}/export"><button>Собрать текущий проверенный корпус</button></form>
              </footer></main></body></html>"""
            payload = page.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)

        def do_POST(self) -> None:
            path = urlparse(self.path).path
            try:
                form = self.form()
                if path == f"/{token}/export":
                    report = export_curated(entries, predictions, state, destination)
                    notice["value"] = (
                        f"Корпус собран: {report['exportedCount']} изображений; "
                        f"неразобранных: {report['unresolvedCount']}."
                    )
                    self.redirect()
                    return
                if path != f"/{token}/decide":
                    self.send_error(404)
                    return
                queue = review_digests(entries, predictions, state)
                if not queue or form.get("digest") != queue[0]:
                    notice["value"] = "Эта CAPTCHA уже обработана; показана следующая."
                    self.redirect()
                    return
                digest = queue[0]
                entry = entries[digest]
                prediction = predictions[digest]
                choice = form.get("choice")
                if choice == "exclude":
                    status, label = "excluded", None
                else:
                    status = "confirmed"
                    label = {
                        "file": entry.label,
                        "model": prediction.value,
                        "custom": form.get("code", "").strip(),
                    }.get(choice, "")
                    if not valid_label(label):
                        notice["value"] = "Введите ровно пять цифр."
                        self.redirect()
                        return
                state["decisions"][digest] = {
                    "status": status,
                    "originalLabel": entry.label,
                    "modelPrediction": prediction.value,
                    "modelConfidence": prediction.confidence,
                    "confirmedLabel": label,
                    "reviewedAt": datetime.now(timezone.utc)
                        .replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                }
                save_state(state_path, state)
                self.redirect()
            except (OSError, ValueError) as error:
                notice["value"] = str(error)
                self.redirect()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    url = f"http://127.0.0.1:{server.server_port}/{token}/"
    print(f"Лаборатория открыта: {url}", flush=True)
    webbrowser.open(url, new=1)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def default_paths() -> tuple[list[Path], list[Path], Path, Path, Path]:
    support = Path.home() / "Library/Application Support/Sudrf"
    training = support / "captcha-training"
    return (
        [Path.home() / "Downloads/solved"],
        [training / "solved-numeric"],
        support / "model-captcha-numeric.mlmodelc",
        training / "sudrf-curation.json",
        training / "solved-numeric-curated",
    )


def main(argv: list[str] | None = None) -> int:
    untrusted_default, trusted_default, model_default, state_default, output_default = default_paths()
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", action="append", type=Path)
    parser.add_argument("--trusted-corpus", action="append", type=Path)
    parser.add_argument("--model", type=Path, default=model_default)
    parser.add_argument("--state", type=Path, default=state_default)
    parser.add_argument("--output", type=Path, default=output_default)
    parser.add_argument("--no-gui", action="store_true")
    args = parser.parse_args(argv)
    untrusted = [path.expanduser().resolve() for path in (args.corpus or untrusted_default)]
    trusted = [path.expanduser().resolve() for path in (args.trusted_corpus or trusted_default)]
    try:
        entries = scan_corpora(untrusted, trusted)
        if not entries:
            raise ValueError("no valid CAPTCHA PNG files found")
        state_path = args.state.expanduser()
        state = load_state(state_path)
        fingerprint = model_fingerprint(args.model.expanduser())
        predictions = predict(
            entries,
            args.model.expanduser(),
            cached=cached_predictions(state, fingerprint),
        )
        state["modelFingerprint"] = fingerprint
        state["predictions"] = {
            digest: {"value": prediction.value, "confidence": prediction.confidence}
            for digest, prediction in predictions.items()
        }
        save_state(state_path, state)
        print(
            f"Уникальных изображений: {len(entries)}; "
            f"расхождений для проверки: {len(review_digests(entries, predictions, state))}"
        )
        if args.no_gui:
            report = export_curated(
                entries, predictions, state, args.output.expanduser()
            )
            print(json.dumps(report, ensure_ascii=False, indent=2))
        else:
            run_web(entries, predictions, state, state_path, args.output.expanduser())
        return 0
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"Подготовка проверки CAPTCHA СОЮ не выполнена: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
