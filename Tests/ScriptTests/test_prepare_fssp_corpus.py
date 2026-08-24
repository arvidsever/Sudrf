import subprocess
import sys
import tempfile
import unittest
from hashlib import sha256
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "prepare-fssp-corpus.py"


def rows(path: Path):
    return path.read_text(encoding="utf-8").splitlines()[1:]


class PrepareFSSPCorpusTests(unittest.TestCase):
    def run_prepare(self, root: Path, corpus: Path, minimum: int, **extra):
        arguments = [
            sys.executable, str(SCRIPT),
            "--corpus", str(corpus),
            "--train-tsv", str(root / "train.tsv"),
            "--validation-tsv", str(root / "validation.tsv"),
            "--exam-tsv", str(root / "exam.tsv"),
            "--minimum", str(minimum),
        ]
        for key, value in extra.items():
            arguments.extend([f"--{key}", str(value)])
        return subprocess.run(arguments, capture_output=True, text=True)

    def test_sha_mod10_split_is_stable_and_deduplicated(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            corpus = root / "corpus"
            corpus.mkdir()
            for index in range(100):
                payload = f"png-{index}".encode()
                digest = sha256(payload).hexdigest()
                (corpus / f"{index:05d}_{digest}.png").write_bytes(payload)

            result = self.run_prepare(root, corpus, 100)
            self.assertEqual(result.returncode, 0, result.stderr)
            train_rows, validation_rows, exam_rows = (
                rows(root / "train.tsv"), rows(root / "validation.tsv"), rows(root / "exam.tsv")
            )
            expected = {
                "train": 0,
                "validation": 0,
                "exam": 0,
            }
            for index in range(100):
                bucket = int(sha256(f"png-{index}".encode()).hexdigest(), 16) % 10
                expected["exam" if bucket == 0 else "validation" if bucket == 5 else "train"] += 1
            self.assertEqual(len(train_rows), expected["train"])
            self.assertEqual(len(validation_rows), expected["validation"])
            self.assertEqual(len(exam_rows), expected["exam"])
            all_rows = train_rows + validation_rows + exam_rows
            self.assertEqual(len({row.split("\t", 1)[0] for row in all_rows}), 100)
            self.assertTrue(set(train_rows).isdisjoint(validation_rows))
            self.assertTrue(set(train_rows).isdisjoint(exam_rows))
            self.assertTrue(set(validation_rows).isdisjoint(exam_rows))

            before = {
                row.split("\t", 1)[0]: "train" for row in train_rows
            }
            before.update({row.split("\t", 1)[0]: "validation" for row in validation_rows})
            before.update({row.split("\t", 1)[0]: "exam" for row in exam_rows})
            payload = b"png-new"
            digest = sha256(payload).hexdigest()
            (corpus / f"99999_{digest}.png").write_bytes(payload)
            result = self.run_prepare(root, corpus, 101)
            self.assertEqual(result.returncode, 0, result.stderr)
            after = {
                row.split("\t", 1)[0]: "train" for row in rows(root / "train.tsv")
            }
            after.update({row.split("\t", 1)[0]: "validation" for row in rows(root / "validation.tsv")})
            after.update({row.split("\t", 1)[0]: "exam" for row in rows(root / "exam.tsv")})
            for path, bucket in before.items():
                self.assertEqual(after[path], bucket)
            self.assertEqual(len(after), 101)

    def test_conflicting_labels_for_same_image_fail(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            corpus = root / "corpus"
            corpus.mkdir()
            payload = b"same-image"
            digest = sha256(payload).hexdigest()
            (corpus / f"12345_{digest}.png").write_bytes(payload)
            (corpus / f"54321_{digest}.png").write_bytes(payload)
            result = self.run_prepare(root, corpus, 1)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("conflicting labels", result.stderr)

    def test_regression_fixture_is_forced_into_exam(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            corpus = root / "corpus"
            corpus.mkdir()
            payloads = []
            for index in range(20):
                payload = f"png-{index}".encode()
                digest = sha256(payload).hexdigest()
                path = corpus / f"{index:05d}_{digest}.png"
                path.write_bytes(payload)
                payloads.append(path)
            regression = root / "regression.tsv"
            regression.write_text(
                "file\tlabel\n" + f"{payloads[1]}\t00001\n", encoding="utf-8"
            )
            result = self.run_prepare(
                root, corpus, 20, **{"regression-tsv": regression}
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(str(payloads[1]), (root / "train.tsv").read_text())
            self.assertNotIn(str(payloads[1]), (root / "validation.tsv").read_text())
            self.assertIn(str(payloads[1]), (root / "exam.tsv").read_text())


if __name__ == "__main__":
    unittest.main()
