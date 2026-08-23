import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "train-fssp-bootstrap.py"
SPEC = importlib.util.spec_from_file_location("train_fssp_bootstrap", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
TRAINER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = TRAINER
SPEC.loader.exec_module(TRAINER)


class TrainFSSPBootstrapTests(unittest.TestCase):
    def test_atomic_replace_publishes_only_staged_model(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            staged = root / "staged.mlmodelc"
            destination = root / "model.mlmodelc"
            staged.mkdir()
            destination.mkdir()
            (staged / "new").write_text("new")
            (destination / "old").write_text("old")

            TRAINER.atomic_replace_directory(staged, destination)

            self.assertTrue((destination / "new").is_file())
            self.assertFalse((destination / "old").exists())
            self.assertFalse(staged.exists())
            self.assertFalse(any("previous" in path.name for path in root.iterdir()))

    def test_atomic_replace_restores_previous_model_on_failure(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            missing_staged = root / "missing.mlmodelc"
            destination = root / "model.mlmodelc"
            destination.mkdir()
            (destination / "old").write_text("old")

            with self.assertRaises(FileNotFoundError):
                TRAINER.atomic_replace_directory(missing_staged, destination)

            self.assertTrue((destination / "old").is_file())
            self.assertFalse(any("previous" in path.name for path in root.iterdir()))

    def test_pinned_environment_matches_training_contract(self):
        requirements = (ROOT / "Scripts/requirements-fssp-bootstrap.txt").read_text().splitlines()
        self.assertEqual(requirements, [
            "coremltools==9.0",
            "torch==2.7.0",
            "numpy==1.26.4",
            "Pillow==11.3.0",
        ])


if __name__ == "__main__":
    unittest.main()
