import importlib.util
import hashlib
import sys
import tempfile
import unittest
from io import BytesIO
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

    def test_v2_contract_and_shared_model_shape(self):
        self.assertEqual(TRAINER.SPLIT_NAME, "sha256-mod10-v2")
        self.assertEqual(TRAINER.PREPROCESSOR_VERSION, "fssp-dominant-span-box-v3")
        self.assertEqual(TRAINER.ARCHITECTURE_VERSION, "fssp-shared-cnn-v2")
        try:
            import torch
        except ModuleNotFoundError:
            self.skipTest("pinned trainer dependencies are not installed")
        helper = TRAINER._load_helper_module()
        model = helper.FSSPSharedCaptchaNet()
        output = model(torch.zeros(2, 1, 20, 64))
        self.assertEqual(tuple(output.shape), (2, 5, 10))
        self.assertEqual(sum(parameter.numel() for parameter in model.parameters()), 23_946)

    def test_affine_parameters_are_deterministic_and_bounded(self):
        first = TRAINER.deterministic_affine_parameters("a" * 64, 42, 7)
        second = TRAINER.deterministic_affine_parameters("a" * 64, 42, 7)
        self.assertEqual(first, second)
        angle, scale, tx, ty = first
        self.assertGreaterEqual(angle, -3.0)
        self.assertLessEqual(angle, 3.0)
        self.assertGreaterEqual(scale, 0.95)
        self.assertLessEqual(scale, 1.05)
        self.assertGreaterEqual(tx, -0.04)
        self.assertLessEqual(tx, 0.04)
        self.assertGreaterEqual(ty, -0.05)
        self.assertLessEqual(ty, 0.05)

    def test_parity_fixtures_use_one_v3_preprocessor(self):
        try:
            import numpy as np
            from PIL import Image
        except ModuleNotFoundError:
            self.skipTest("pinned trainer dependencies are not installed")
        fixture_tsv = ROOT / "Tests/CaptchaSolverTests/Fixtures/fssp/parity.tsv"
        if not fixture_tsv.is_file():
            self.skipTest("parity fixtures are not present")
        with fixture_tsv.open(encoding="utf-8") as stream:
            next(stream)
            rows = [line.rstrip("\n").split("\t") for line in stream if line.strip()]
        self.assertEqual(len(rows), 3)
        expected_digests = {
            "08212_136d6d2dc3d1590fbf0fb6da6b951acfd3758f5a584f1ee06d89cf7e85d20b2e.png": "eaead2cbe2e5b1fb8b15e9e3d1fe2f139c70eb77d4fa3a2baa4a53cb8d76e940",
            "17758_c7d58b9cfa1ec518a7e4f2bc0ad271a710c01587ef3fae2a0c09075f50f03b0c.png": "6ccc056cff8cc20bed8fed7cb7062631e6f172abda05b0d78af967ec8658fcdf",
            "62442_a2ec40e6966369d794d68caaf970beee7eef7f83f7b0104398564b1ffca5fdd2.png": "aa8222ae7ae7b8924c7c10a38e645b29ebe94ad32478e77ba70a9986ac11d198",
        }
        for relative_path, _ in rows:
            image_path = fixture_tsv.parent / relative_path
            png = image_path.read_bytes()
            from_trainer = TRAINER.fssp_dominant_span_box_v3(png, np, Image)
            helper = TRAINER._load_helper_module()
            from_helper = helper.fssp_dominant_span_box_v3(png)
            np.testing.assert_array_equal(from_trainer, from_helper)
            self.assertEqual(from_trainer.shape, (20, 64))
            quantized = np.rint(from_trainer * 48).astype(np.uint8)
            self.assertEqual(
                hashlib.sha256(quantized.tobytes(order="C")).hexdigest(),
                expected_digests[image_path.name],
            )

    def test_v3_rejects_partial_transparency(self):
        try:
            from PIL import Image
        except ModuleNotFoundError:
            self.skipTest("pinned trainer dependencies are not installed")
        image = Image.new("RGBA", (240, 80), (0, 0, 0, 0))
        for y in range(20, 60):
            for x in range(100, 171):
                image.putpixel((x, y), (20, 18, 49, 128))
        output = BytesIO()
        image.save(output, format="PNG")
        with self.assertRaisesRegex(ValueError, "partial transparency"):
            TRAINER.fssp_dominant_span_box_v3(output.getvalue())


if __name__ == "__main__":
    unittest.main()
