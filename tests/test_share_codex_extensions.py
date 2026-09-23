"""Containment tests for the optional Codex extension sharing tool."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "share-codex-extensions.py"


class ShareExtensionsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.homes = [self.root / "first", self.root / "second"]
        for home in self.homes:
            (home / "skills").mkdir(parents=True)
        self.shared = self.root / "shared-skills"
        self.cli = self.root / "codex"
        self.cli.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, sys\n"
            "assert sys.argv[1:3] == ['plugin', 'add']\n"
            "home = pathlib.Path(os.environ['CODEX_HOME'])\n"
            "name = sys.argv[3]\n"
            "with (home / 'config.toml').open('a') as file:\n"
            "    file.write('\\n[plugins.\"' + name + '\"]\\nenabled = true\\n')\n"
        )
        self.cli.chmod(0o755)

    def run_tool(self, *extra):
        return subprocess.run(
            [sys.executable, str(SCRIPT),
             "--home", str(self.homes[0]), "--home", str(self.homes[1]),
             "--shared-skills", str(self.shared), "--codex-bin", str(self.cli),
             *extra], capture_output=True, text=True,
        )

    def test_plan_is_read_only_and_apply_reconciles_both_homes(self):
        (self.homes[0] / "skills" / "first-skill").mkdir()
        (self.homes[0] / "skills" / "first-skill" / "SKILL.md").write_text("first")
        (self.homes[1] / "skills" / "second-skill").mkdir()
        (self.homes[1] / "skills" / "second-skill" / "SKILL.md").write_text("second")
        (self.homes[0] / "config.toml").write_text('[plugins."plugin-a@market"]\nenabled = true\n')
        (self.homes[1] / "config.toml").write_text('[plugins."plugin-b@market"]\nenabled = true\n')
        (self.homes[0] / "auth.json").write_text("account-a")
        (self.homes[1] / "auth.json").write_text("account-b")

        plan = self.run_tool()
        self.assertEqual(plan.returncode, 0, plan.stderr)
        self.assertFalse(self.shared.exists())
        self.assertNotIn('plugin-b@market', (self.homes[0] / 'config.toml').read_text())

        applied = self.run_tool("--apply")
        self.assertEqual(applied.returncode, 0, applied.stderr)
        self.assertTrue((self.shared / "first-skill").is_symlink())
        self.assertTrue((self.shared / "second-skill").is_symlink())
        self.assertIn('plugin-b@market', (self.homes[0] / 'config.toml').read_text())
        self.assertIn('plugin-a@market', (self.homes[1] / 'config.toml').read_text())
        self.assertEqual((self.homes[0] / "auth.json").read_text(), "account-a")
        self.assertEqual((self.homes[1] / "auth.json").read_text(), "account-b")
        self.assertIn("Plugin installations: 0", self.run_tool().stdout)

    def test_conflicting_skill_aborts_before_changes(self):
        for home, text in zip(self.homes, ("different-a", "different-b")):
            skill = home / "skills" / "same-name"
            skill.mkdir()
            (skill / "SKILL.md").write_text(text)
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs", result.stderr)
        self.assertFalse(self.shared.exists())


if __name__ == "__main__":
    unittest.main()
