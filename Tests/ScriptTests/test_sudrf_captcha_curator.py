import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "sudrf-captcha-curator.py"
SPEC = importlib.util.spec_from_file_location("sudrf_captcha_curator", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
CURATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CURATOR
SPEC.loader.exec_module(CURATOR)


def write_png(path: Path, colour: tuple[int, int, int]) -> None:
    Image.new("RGB", (100, 30), colour).save(path)


class SudrfCaptchaCuratorTests(unittest.TestCase):
    def test_trusted_label_wins_and_export_is_non_destructive(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            untrusted = root / "friend"
            trusted = root / "server"
            output = root / "curated"
            untrusted.mkdir()
            trusted.mkdir()
            friend = untrusted / "12345_friend.png"
            server = trusted / "54321_server.png"
            write_png(friend, (1, 2, 3))
            server.write_bytes(friend.read_bytes())

            entries = CURATOR.scan_corpora([untrusted], [trusted])
            self.assertEqual(len(entries), 1)
            entry = next(iter(entries.values()))
            self.assertTrue(entry.trusted)
            self.assertEqual(entry.label, "54321")
            predictions = {entry.digest: CURATOR.Prediction("12345", 1.0)}
            report = CURATOR.export_curated(
                entries, predictions, {"version": 1, "decisions": {}}, output
            )

            self.assertEqual(report["serverConfirmedCount"], 1)
            self.assertEqual(report["exportedCount"], 1)
            self.assertTrue(friend.is_file())
            self.assertTrue(server.is_file())
            self.assertTrue((output / f"54321_{entry.digest}.png").is_file())

    def test_disagreement_waits_for_manual_confirmation(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            corpus = root / "friend"
            corpus.mkdir()
            image = corpus / "12345_friend.png"
            write_png(image, (3, 2, 1))
            entries = CURATOR.scan_corpora([corpus], [])
            entry = next(iter(entries.values()))
            predictions = {entry.digest: CURATOR.Prediction("54321", 0.99)}
            state = {"version": 1, "decisions": {}}

            self.assertEqual(CURATOR.review_digests(entries, predictions, state), [entry.digest])
            first = CURATOR.export_curated(entries, predictions, state, root / "first")
            self.assertEqual(first["unresolvedCount"], 1)
            self.assertEqual(first["exportedCount"], 0)

            state["decisions"][entry.digest] = {
                "status": "confirmed", "confirmedLabel": "54321"
            }
            second = CURATOR.export_curated(entries, predictions, state, root / "second")
            self.assertEqual(second["manuallyConfirmedCount"], 1)
            self.assertTrue((root / "second" / f"54321_{entry.digest}.png").is_file())

    def test_same_label_duplicate_is_exported_once(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            corpus = root / "friend"
            corpus.mkdir()
            first = corpus / "12345_a.png"
            second = corpus / "12345_b.png"
            write_png(first, (7, 8, 9))
            second.write_bytes(first.read_bytes())
            entries = CURATOR.scan_corpora([corpus], [])
            self.assertEqual(len(entries), 1)
            entry = next(iter(entries.values()))
            predictions = {entry.digest: CURATOR.Prediction("12345", 0.8)}
            report = CURATOR.export_curated(
                entries, predictions, {"version": 1, "decisions": {}}, root / "curated"
            )
            self.assertEqual(report["modelAgreedCount"], 1)
            self.assertEqual(report["exportedCount"], 1)

    def test_prediction_cache_is_bound_to_model_fingerprint(self):
        state = {
            "version": 1,
            "decisions": {},
            "modelFingerprint": "model-a",
            "predictions": {"digest": {"value": "12345", "confidence": 0.75}},
        }
        cached = CURATOR.cached_predictions(state, "model-a")
        self.assertEqual(cached["digest"], CURATOR.Prediction("12345", 0.75))
        self.assertEqual(CURATOR.cached_predictions(state, "model-b"), {})


if __name__ == "__main__":
    unittest.main()
