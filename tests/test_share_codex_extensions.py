"""Containment tests for the optional Codex extension sharing tool."""

import os
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
            r'''#!/usr/bin/env python3
import json, os, pathlib, sys, tomllib
home = pathlib.Path(os.environ['CODEX_HOME'])
config = home / 'config.toml'
data = tomllib.loads(config.read_text()) if config.exists() else {}
marker = home / '.installed-plugins'
installed = set(marker.read_text().splitlines()) if marker.exists() else set()
args = sys.argv[1:]
if args == ['plugin', 'list', '--json']:
    print(json.dumps({'installed': [
        {'pluginId': name, 'installed': True,
         'enabled': data.get('plugins', {}).get(name, {}).get('enabled') is True}
        for name in sorted(installed)], 'available': []}))
elif args == ['plugin', 'marketplace', 'list', '--json']:
    print(json.dumps({'marketplaces': [
        {'name': name} for name in sorted(data.get('marketplaces', {}))]}))
elif args[:3] == ['plugin', 'marketplace', 'add']:
    source = args[3]
    name = pathlib.Path(source).name
    with config.open('a') as file:
        file.write(f'\n[marketplaces.{name}]\nsource_type = "local"\nsource = "{source}"\n')
elif args[:2] == ['plugin', 'add']:
    name = args[2]
    market = name.rsplit('@', 1)[-1]
    if market in ('team', 'openai-bundled', 'openai-primary-runtime'):
        assert market in data.get('marketplaces', {}), 'marketplace unavailable'
    if name not in data.get('plugins', {}):
        with config.open('a') as file:
            file.write(f'\n[plugins."{name}"]\nenabled = true\n')
    if os.environ.get('FAKE_CODEX_ADD_NO_INSTALL') != '1':
        installed.add(name)
        marker.write_text('\n'.join(sorted(installed)) + '\n')
else:
    raise SystemExit(f'unexpected command: {args}')
'''
        )
        self.cli.chmod(0o755)

    def run_tool(self, *extra, env=None):
        return subprocess.run(
            [sys.executable, str(SCRIPT),
             "--home", str(self.homes[0]), "--home", str(self.homes[1]),
             "--shared-skills", str(self.shared), "--codex-bin", str(self.cli),
             *extra], capture_output=True, text=True, env=env,
        )

    def test_plan_does_not_change_extensions_and_apply_reconciles_both_homes(self):
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

    def test_enabled_without_installation_is_repaired(self):
        plugin = "sample@market"
        (self.homes[0] / "config.toml").write_text(
            f'[plugins."{plugin}"]\nenabled = true\n'
        )
        plan = self.run_tool()
        self.assertEqual(plan.returncode, 0, plan.stderr)
        self.assertIn("Plugin installations: 2", plan.stdout)
        self.assertFalse((self.homes[0] / ".installed-plugins").exists())

        applied = self.run_tool("--apply")
        self.assertEqual(applied.returncode, 0, applied.stderr)
        for home in self.homes:
            self.assertIn(plugin, (home / ".installed-plugins").read_text())
        self.assertIn("Plugin installations: 0", self.run_tool().stdout)

    def test_cli_success_without_installed_postcondition_fails(self):
        (self.homes[0] / "config.toml").write_text(
            '[plugins."sample@market"]\nenabled = true\n'
        )
        result = self.run_tool("--apply", env={**os.environ, "FAKE_CODEX_ADD_NO_INSTALL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAILED plugin install", result.stderr)
        self.assertIn("Plugin installations: 2", self.run_tool().stdout)

    def test_missing_builtin_marketplace_refuses_before_skill_links(self):
        skill = self.homes[0] / "skills" / "source-skill"
        skill.mkdir()
        (skill / "SKILL.md").write_text("safe")
        (self.homes[0] / "config.toml").write_text(
            f'[marketplaces.openai-bundled]\nsource_type = "local"\n'
            f'source = "{self.root / "bundled"}"\n'
            '[plugins."browser@openai-bundled"]\nenabled = true\n'
        )
        (self.homes[0] / ".installed-plugins").write_text("browser@openai-bundled\n")
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("built-in marketplace", result.stderr)
        self.assertFalse(self.shared.exists())
        self.assertFalse((self.homes[1] / "config.toml").exists())

    def test_conflicting_skill_aborts_before_changes(self):
        for home, text in zip(self.homes, ("different-a", "different-b")):
            skill = home / "skills" / "same-name"
            skill.mkdir()
            (skill / "SKILL.md").write_text(text)
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs", result.stderr)
        self.assertFalse(self.shared.exists())

    def test_identical_local_copies_are_replaced_with_shared_link(self):
        for home in self.homes:
            skill = home / "skills" / "same-name"
            skill.mkdir()
            (skill / "SKILL.md").write_text("initial")
        applied = self.run_tool("--apply")
        self.assertEqual(applied.returncode, 0, applied.stderr)
        self.assertTrue((self.shared / "same-name").is_symlink())
        self.assertTrue((self.homes[1] / "skills" / "same-name").is_symlink())
        backups = list((self.homes[1] / "skills").glob(".same-name.before-sharing-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "SKILL.md").read_text(), "initial")
        (self.homes[0] / "skills" / "same-name" / "SKILL.md").write_text("updated")
        self.assertEqual((self.homes[1] / "skills" / "same-name" / "SKILL.md").read_text(), "updated")
        self.assertIn("Local skill copies to unify: 0", self.run_tool().stdout)

    def test_custom_marketplace_is_added_before_plugin(self):
        market = self.root / "team"
        market.mkdir()
        (self.homes[0] / "config.toml").write_text(
            f'[marketplaces.team]\nsource_type = "local"\nsource = "{market}"\n'
            '[plugins."sample@team"]\nenabled = true\n'
        )
        applied = self.run_tool("--apply")
        self.assertEqual(applied.returncode, 0, applied.stderr)
        config = (self.homes[1] / "config.toml").read_text()
        self.assertIn("[marketplaces.team]", config)
        self.assertIn('[plugins."sample@team"]', config)
        self.assertIn("Marketplaces to add: 0", self.run_tool().stdout)

    def test_conflicting_marketplace_aborts_before_skill_changes(self):
        for home, source in zip(self.homes, ("source-a", "source-b")):
            (home / "config.toml").write_text(
                f'[marketplaces.team]\nsource_type = "local"\nsource = "{self.root / source}"\n'
            )
        with (self.homes[0] / "config.toml").open("a") as config:
            config.write('[plugins."sample@team"]\nenabled = true\n')
        skill = self.homes[0] / "skills" / "skill"
        skill.mkdir()
        (skill / "SKILL.md").write_text("test")
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("conflicting sources", result.stderr)
        self.assertFalse(self.shared.exists())
        self.assertFalse((self.homes[1] / "config.toml").read_text().count("sample@team"))

    def test_conflicting_marketplace_fails_even_without_installations(self):
        for home, source in zip(self.homes, ("source-a", "source-b")):
            (home / "config.toml").write_text(
                f'[marketplaces.team]\nsource_type = "local"\nsource = "{self.root / source}"\n'
                '[plugins."sample@team"]\nenabled = true\n'
            )
        result = self.run_tool()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("conflicting sources", result.stderr)

    def test_unknown_marketplace_origin_aborts_before_changes(self):
        third = self.root / "third"
        (third / "skills").mkdir(parents=True)
        (self.homes[0] / "config.toml").write_text(
            '[plugins."sample@team"]\nenabled = true\n'
        )
        (self.homes[1] / "config.toml").write_text(
            f'[marketplaces.team]\nsource_type = "local"\nsource = "{self.root / "team"}"\n'
            '[plugins."sample@team"]\nenabled = true\n'
        )
        result = subprocess.run(
            [sys.executable, str(SCRIPT),
             *[item for home in (*self.homes, third) for item in ("--home", str(home))],
             "--shared-skills", str(self.shared), "--codex-bin", str(self.cli), "--apply"],
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot verify marketplace", result.stderr)
        self.assertFalse(self.shared.exists())

    def test_skill_link_outside_its_directory_aborts_before_changes(self):
        for home, value in zip(self.homes, ("A", "B")):
            skill = home / "skills" / "same-name"
            skill.mkdir()
            (skill / "SKILL.md").write_text("same")
            (home / "skills" / "resource").mkdir()
            (home / "skills" / "resource" / "data.txt").write_text(value)
            (skill / "data").symlink_to("../resource")
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("escapes its directory", result.stderr)
        self.assertFalse(self.shared.exists())

    def test_skill_permissions_must_match_before_unifying(self):
        for home, mode in zip(self.homes, (0o644, 0o755)):
            skill = home / "skills" / "same-name"
            skill.mkdir()
            (skill / "SKILL.md").write_text("same")
            script = skill / "run.sh"
            script.write_text("#!/bin/sh\nexit 0\n")
            script.chmod(mode)
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs", result.stderr)
        self.assertFalse(self.shared.exists())

    @unittest.skipIf(os.geteuid() == 0, "root can traverse mode 000 directories")
    def test_unreadable_skill_directory_refuses_before_unifying(self):
        locked = []
        try:
            for home, value in zip(self.homes, ("A", "B")):
                skill = home / "skills" / "same-name"
                hidden = skill / "locked"
                hidden.mkdir(parents=True)
                (skill / "SKILL.md").write_text("same")
                (hidden / "data.txt").write_text(value)
                hidden.chmod(0)
                locked.append(hidden)
            result = self.run_tool("--apply")
        finally:
            for hidden in locked:
                hidden.chmod(0o700)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot read skill directory", result.stderr)
        self.assertFalse(self.shared.exists())
        self.assertEqual((locked[1] / "data.txt").read_text(), "B")

    def test_same_shared_skill_with_external_link_needs_no_unification(self):
        skill = self.shared / "existing"
        skill.mkdir(parents=True)
        (skill / "SKILL.md").write_text("same")
        external = self.root / "runtime"
        external.write_text("runtime")
        (skill / "runtime").symlink_to(external)
        for home in self.homes:
            (home / "skills" / "existing").symlink_to(skill, target_is_directory=True)
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Local skill copies to unify: 0", result.stdout)

    def test_shared_directory_inside_source_skill_is_rejected(self):
        for home in self.homes:
            skill = home / "skills" / "demo"
            skill.mkdir()
            (skill / "SKILL.md").write_text("same")
        nested = self.homes[0] / "skills" / "demo" / "shared"
        result = subprocess.run(
            [sys.executable, str(SCRIPT),
             *[item for home in self.homes for item in ("--home", str(home))],
             "--shared-skills", str(nested), "--codex-bin", str(self.cli), "--apply"],
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("inside source skill", result.stderr)
        self.assertFalse(nested.exists())


if __name__ == "__main__":
    unittest.main()
