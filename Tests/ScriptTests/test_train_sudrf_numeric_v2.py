import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "train-sudrf-numeric-v2.py"
SPEC = importlib.util.spec_from_file_location("train_sudrf_numeric_v2", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
TRAINER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = TRAINER
SPEC.loader.exec_module(TRAINER)


class TrainSudrfNumericV2Tests(unittest.TestCase):
    def test_contract_uses_independent_split_and_separate_draft_model(self):
        self.assertEqual(TRAINER.SPLIT_NAME, "sha256-mod10-v2")
        self.assertEqual(TRAINER.PREPROCESSOR_VERSION, "sudrf-teal-box-v1")
        self.assertEqual(TRAINER.ARCHITECTURE_VERSION, "sudrf-shared-cnn-v2")
        self.assertEqual(TRAINER.MODEL_NAME, "model-captcha-numeric-v2")
        self.assertEqual(TRAINER.TARGET_EXACT_ACCURACY, 0.98)
        self.assertEqual(TRAINER.REGRESSION_OVERSAMPLE, 64)

    def test_shared_model_preserves_runtime_tensor_contract(self):
        try:
            import torch
        except ModuleNotFoundError:
            self.skipTest("pinned trainer dependencies are not installed")
        _, _, helper, _ = TRAINER._dependencies()
        model = helper.SharedCaptchaNet()
        output = model(torch.zeros(2, 1, 20, 64))
        self.assertEqual(tuple(output.shape), (2, 5, 10))
        self.assertEqual(sum(parameter.numel() for parameter in model.parameters()), 23_946)

    def test_fixed_pool_matches_adaptive_pool_used_by_the_model_contract(self):
        try:
            import torch
        except ModuleNotFoundError:
            self.skipTest("pinned trainer dependencies are not installed")
        _, _, helper, _ = TRAINER._dependencies()
        feature_map = torch.arange(2 * 64 * 5 * 16, dtype=torch.float32).reshape(
            2, 64, 5, 16
        )
        actual = helper.SharedCaptchaNet().pool(feature_map)
        expected = torch.nn.functional.adaptive_avg_pool2d(feature_map, (1, 5))
        self.assertTrue(torch.equal(actual, expected))

    def test_known_court_regressions_are_three_unique_confirmed_images(self):
        try:
            import torch  # noqa: F401
        except ModuleNotFoundError:
            self.skipTest("pinned trainer dependencies are not installed")
        _, _, helper, training = TRAINER._dependencies()
        samples = TRAINER.load_regression_samples(
            TRAINER.REGRESSION_LABELS, helper, training
        )
        self.assertEqual(len(samples), 3)
        labels = {"".join(str(digit) for digit in sample.label) for sample in samples}
        self.assertEqual(labels, {"90299", "56667", "60984"})
        self.assertEqual(len({sample.digest for sample in samples}), 3)


if __name__ == "__main__":
    unittest.main()
