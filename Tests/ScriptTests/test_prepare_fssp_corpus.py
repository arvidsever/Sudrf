import subprocess
import sys
import tempfile
import unittest
from hashlib import sha256
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "prepare-fssp-corpus.py"


class PrepareFSSPCorpusTests(unittest.TestCase):
    def test_sha_split_is_deduplicated_and_exactly_80_20(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            corpus = root / "corpus"
            corpus.mkdir()
            for index in range(10):
                payload = f"png-{index}".encode()
                digest = sha256(payload).hexdigest()
                (corpus / f"{index:05d}_{digest}.png").write_bytes(payload)

            train = root / "train.tsv"
            test = root / "test.tsv"
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--corpus", str(corpus),
                 "--train-tsv", str(train), "--test-tsv", str(test),
                 "--minimum", "10"], capture_output=True, text=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            train_rows = train.read_text().splitlines()[1:]
            test_rows = test.read_text().splitlines()[1:]
            self.assertEqual(len(train_rows), 8)
            self.assertEqual(len(test_rows), 2)
            self.assertTrue(set(train_rows).isdisjoint(test_rows))

    def test_conflicting_labels_for_same_image_fail(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            corpus = root / "corpus"
            corpus.mkdir()
            payload = b"same-image"
            digest = sha256(payload).hexdigest()
            (corpus / f"12345_{digest}.png").write_bytes(payload)
            (corpus / f"54321_{digest}.png").write_bytes(payload)

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--corpus", str(corpus),
                 "--train-tsv", str(root / "train.tsv"),
                 "--test-tsv", str(root / "test.tsv"),
                 "--minimum", "1"], capture_output=True, text=True)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("conflicting labels", result.stderr)


if __name__ == "__main__":
    unittest.main()
