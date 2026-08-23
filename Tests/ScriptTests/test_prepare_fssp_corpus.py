import subprocess
import sys
import tempfile
import unittest
from hashlib import sha256
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "prepare-fssp-corpus.py"


class PrepareFSSPCorpusTests(unittest.TestCase):
    def test_sha_split_is_stable_and_deduplicated(self):
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
            expected_held_out = sum(
                int(sha256(f"png-{index}".encode()).hexdigest(), 16) % 5 == 0
                for index in range(10)
            )
            self.assertEqual(len(test_rows), expected_held_out)
            self.assertEqual(len(train_rows), 10 - expected_held_out)
            self.assertTrue(set(train_rows).isdisjoint(test_rows))

            # Adding a new image must not move an existing digest across the
            # split. This is the property a sorted 80/20 split did not have.
            before = {row.split("\t", 1)[0]: "train" for row in train_rows}
            before.update({row.split("\t", 1)[0]: "held-out" for row in test_rows})
            payload = b"png-new"
            digest = sha256(payload).hexdigest()
            (corpus / f"99999_{digest}.png").write_bytes(payload)
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--corpus", str(corpus),
                 "--train-tsv", str(train), "--test-tsv", str(test),
                 "--minimum", "11"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            after_rows = train.read_text().splitlines()[1:] + test.read_text().splitlines()[1:]
            after = {row.split("\t", 1)[0]: "train" for row in train.read_text().splitlines()[1:]}
            after.update({row.split("\t", 1)[0]: "held-out" for row in test.read_text().splitlines()[1:]})
            for path, bucket in before.items():
                self.assertEqual(after[path], bucket)
            self.assertEqual(len(after_rows), 11)

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

    def test_regression_fixture_is_forced_held_out(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            corpus = root / "corpus"
            corpus.mkdir()
            rows = []
            for index in range(5):
                payload = f"png-{index}".encode()
                digest = sha256(payload).hexdigest()
                path = corpus / f"{index:05d}_{digest}.png"
                path.write_bytes(payload)
                rows.append(path)
            regression = root / "regression.tsv"
            regression.write_text(
                "file\tlabel\n" + f"{rows[1]}\t00001\n", encoding="utf-8"
            )
            train = root / "train.tsv"
            held_out = root / "held-out.tsv"
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--corpus", str(corpus),
                 "--train-tsv", str(train), "--test-tsv", str(held_out),
                 "--regression-tsv", str(regression), "--minimum", "5"],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(str(rows[1]), train.read_text())
            self.assertIn(str(rows[1]), held_out.read_text())


if __name__ == "__main__":
    unittest.main()
