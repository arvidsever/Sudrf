import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "generate-legal-deadline-registry.py"
SOURCE_DIR = ROOT / "Docs" / "legal-deadlines"
RESOURCE = ROOT / "Sources" / "SudrfKit" / "Resources" / "LegalDeadlineRegistry.json"
FENCE = re.compile(r"```json\s*(.*?)\s*```", re.S)


class LegalDeadlineRegistryScriptTests(unittest.TestCase):
    def test_resource_is_generated_and_has_complete_catalog(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--check"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        registry = json.loads(RESOURCE.read_text(encoding="utf-8"))
        self.assertEqual(len(registry["coreRules"]), 66)
        self.assertEqual(len({rule["rule_id"] for rule in registry["coreRules"]}), 66)
        self.assertEqual(len(registry["sources"]), 4)
        self.assertEqual(len(registry["policies"]), 39)
        self.assertEqual(len(registry["triggerDependencies"]), 42)
        self.assertEqual(len(registry["constraints"]), 10)
        self.assertEqual(len(registry["exclusions"]), 15)
        self.assertEqual(len(registry["openQuestions"]), 9)

        for source in registry["sources"]:
            markdown = (ROOT / source["document"]).read_bytes()
            self.assertEqual(source["markdownSha256"], hashlib.sha256(markdown).hexdigest())
            self.assertEqual(source["payload"]["artifact"]["revision"], source["revision"])
            self.assertEqual(source["payload"]["source"]["sha256"], source["sourceHash"])

        kinds = {rule["duration"]["kind"] for rule in registry["coreRules"]}
        self.assertTrue({"calendarDays", "calendarSutki", "workingDays", "months", "relative", "none"} <= kinds)
        self.assertEqual(
            next(rule for rule in registry["coreRules"] if rule["rule_id"] == "KAS-CASSATION-SUPREME-COURT")["duration"]["kind"],
            "relative",
        )
        self.assertEqual(
            next(rule for rule in registry["coreRules"] if rule["rule_id"] == "KOAP-APPEAL-RETURN-DETERMINATION-ONE-SUTKI")["duration"]["kind"],
            "calendarSutki",
        )

    def test_unknown_duration_is_a_generation_error(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary_sources = Path(directory)
            for source in SOURCE_DIR.glob("*-appeal-deadlines.md"):
                shutil.copy2(source, temporary_sources / source.name)
            path = temporary_sources / "gpk-appeal-deadlines.md"
            text = path.read_text(encoding="utf-8")
            payload = json.loads(FENCE.search(text).group(1))
            payload["coreRules"][0]["duration"] = "пример неизвестной формулы"
            path.write_text(FENCE.sub("```json\n" + json.dumps(payload, ensure_ascii=False, indent=2) + "\n```", text), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--source-dir", str(temporary_sources), "--output", str(temporary_sources / "out.json")],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unknown duration formula", result.stderr)

    def test_lost_rule_is_a_generation_error(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary_sources = Path(directory)
            for source in SOURCE_DIR.glob("*-appeal-deadlines.md"):
                shutil.copy2(source, temporary_sources / source.name)
            path = temporary_sources / "upk-appeal-deadlines.md"
            text = path.read_text(encoding="utf-8")
            payload = json.loads(FENCE.search(text).group(1))
            payload["coreRules"].pop()
            path.write_text(FENCE.sub("```json\n" + json.dumps(payload, ensure_ascii=False, indent=2) + "\n```", text), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--source-dir", str(temporary_sources), "--output", str(temporary_sources / "out.json")],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("expected 14 core rules", result.stderr)

    def test_duplicate_source_rule_id_is_a_generation_error(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary_sources = Path(directory)
            for source in SOURCE_DIR.glob("*-appeal-deadlines.md"):
                shutil.copy2(source, temporary_sources / source.name)
            path = temporary_sources / "gpk-appeal-deadlines.md"
            text = path.read_text(encoding="utf-8")
            payload = json.loads(FENCE.search(text).group(1))
            payload["coreRules"][1]["rule_id"] = payload["coreRules"][0]["rule_id"]
            path.write_text(
                FENCE.sub(
                    "```json\n"
                    + json.dumps(payload, ensure_ascii=False, indent=2)
                    + "\n```",
                    text,
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--source-dir",
                    str(temporary_sources),
                    "--output",
                    str(temporary_sources / "out.json"),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("duplicate rule_id", result.stderr)


if __name__ == "__main__":
    unittest.main()
