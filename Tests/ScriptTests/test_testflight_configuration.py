import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class TestFlightConfigurationTests(unittest.TestCase):
    def test_sandbox_entitlements_are_minimal(self):
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        expected = {
            "com.apple.security.app-sandbox: true",
            "com.apple.security.network.client: true",
            "com.apple.security.files.user-selected.read-write: true",
        }
        for entitlement in expected:
            self.assertIn(entitlement, project)
        self.assertIn("path: Generated/Sudrf.entitlements", project)

    def test_container_migration_is_limited_to_sudrf_files(self):
        manifest = ROOT / "Sources" / "SudrfApp" / "Resources" / "container-migration.plist"
        with manifest.open("rb") as source:
            values = plistlib.load(source)
        self.assertEqual(
            values,
            {
                "Move": [
                    "${ApplicationSupport}/default.store",
                    "${ApplicationSupport}/default.store-wal",
                    "${ApplicationSupport}/default.store-shm",
                    "${ApplicationSupport}/Sudrf",
                    "${Library}/Preferences/${BundleId}.plist",
                ]
            },
        )
        self.assertNotIn("${ApplicationSupport}", values["Move"])
        self.assertNotIn("${Home}", values["Move"])


if __name__ == "__main__":
    unittest.main()
