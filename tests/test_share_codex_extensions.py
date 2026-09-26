"""Containment tests for the optional Codex extension sharing tool."""

from contextlib import redirect_stdout
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "share-codex-extensions.py"


class ShareExtensionsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.homes = [self.root / "first", self.root / "second"]
        for home in self.homes:
            (home / "skills").mkdir(parents=True)
            (home / ".available-plugins").write_text(
                "plugin-a@market\nplugin-b@market\nsample@market\nsample@team\n"
                "browser@openai-bundled\n"
            )
        self.shared = self.root / ".agents" / "skills"
        self.cli = self.root / "codex"
        self.cli.write_text(
            r'''#!/usr/bin/env python3
import json, os, pathlib, sys, tomllib
home = pathlib.Path(os.environ['CODEX_HOME'])
config = home / 'config.toml'
data = tomllib.loads(config.read_text()) if config.exists() else {}
marker = home / '.installed-plugins'
installed = set(marker.read_text().splitlines()) if marker.exists() else set()
catalog = home / '.available-plugins'
available = set(catalog.read_text().splitlines()) if catalog.exists() else set()
implicit_marker = home / '.implicit-marketplaces.json'
implicit = json.loads(implicit_marker.read_text()) if implicit_marker.exists() else {}
origin_marker = home / '.marketplace-origin-overrides.json'
origins = json.loads(origin_marker.read_text()) if origin_marker.exists() else {}
omit_marker = home / '.omit-marketplaces'
omit = set(omit_marker.read_text().splitlines()) if omit_marker.exists() else set()
blocked_marker = home / '.not-installable-plugins'
blocked = set(blocked_marker.read_text().splitlines()) if blocked_marker.exists() else set()
def policy(name):
    return 'NOT_AVAILABLE' if name in blocked else 'AVAILABLE'
args = sys.argv[1:]
if args == ['plugin', 'list', '--available', '--json']:
    mutate = os.environ.get('FAKE_CODEX_MUTATE_SKILL')
    if mutate:
        changed = home / '.mutated-skill-once'
        if not changed.exists():
            pathlib.Path(mutate).write_text('changed during plugin query')
            changed.write_text('done')
    print(json.dumps({'installed': [
        {'pluginId': name, 'installed': True, 'installPolicy': policy(name),
         'enabled': data.get('plugins', {}).get(name, {}).get('enabled') is True}
        for name in sorted(installed)],
        'available': [{'pluginId': name, 'installPolicy': policy(name)}
                      for name in sorted(available - installed)]}))
elif args == ['plugin', 'marketplace', 'list', '--json']:
    configured = data.get('marketplaces', {})
    print(json.dumps({'marketplaces': [
        {'name': name, 'marketplaceSource': origins.get(name, {
            'sourceType': spec.get('source_type'),
            'source': str(pathlib.Path(spec.get('source', '')).expanduser().resolve())})}
        for name, spec in sorted(configured.items()) if name not in omit] + [
        {'name': name, 'marketplaceSource': {
            'sourceType': 'local', 'source': str(pathlib.Path(source).resolve())}}
        for name, source in sorted(implicit.items()) if name not in configured]}))
elif args[:3] == ['plugin', 'marketplace', 'add']:
    source = str(pathlib.Path(args[3]).resolve())
    name = pathlib.Path(source).name
    with config.open('a') as file:
        file.write(f'\n[marketplaces.{name}]\nsource_type = "local"\nsource = "{source}"\n')
elif args[:2] == ['plugin', 'add']:
    name = args[2]
    if name in blocked:
        raise SystemExit('plugin not available for install')
    market = name.rsplit('@', 1)[-1]
    if market in ('team', 'openai-bundled', 'openai-primary-runtime'):
        assert market in data.get('marketplaces', {}) or market in implicit, 'marketplace unavailable'
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
        run_env = {**os.environ, **(env or {}), "HOME": str(self.root)}
        return subprocess.run(
            [sys.executable, str(SCRIPT),
             "--home", str(self.homes[0]), "--home", str(self.homes[1]),
             "--shared-skills", str(self.shared), "--codex-bin", str(self.cli),
             *extra], capture_output=True, text=True, env=run_env,
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

    def test_unavailable_account_level_plugin_refuses_before_skill_links(self):
        skill = self.homes[0] / "skills" / "source-skill"
        skill.mkdir()
        (skill / "SKILL.md").write_text("safe")
        (self.homes[0] / "config.toml").write_text(
            '[plugins."absent@no-such-market"]\nenabled = true\n'
        )
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is unavailable", result.stderr)
        self.assertFalse(self.shared.exists())

    def test_listed_but_not_installable_plugin_refuses_before_skill_links(self):
        skill = self.homes[0] / "skills" / "source-skill"
        skill.mkdir()
        (skill / "SKILL.md").write_text("safe")
        (self.homes[0] / "config.toml").write_text(
            '[plugins."plugin-a@market"]\nenabled = true\n'
        )
        (self.homes[1] / ".not-installable-plugins").write_text("plugin-a@market\n")
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not installable", result.stderr)
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

    def test_skill_digest_framing_rejects_different_trees(self):
        for home in self.homes:
            skill = home / "skills" / "same-name"
            skill.mkdir()
            (skill / "SKILL.md").write_text("same")
        first = self.homes[0] / "skills" / "same-name"
        second = self.homes[1] / "skills" / "same-name"
        (first / "a").write_bytes(b"bfile\x00420\x00")
        (second / "a").write_bytes(b"")
        (second / "b").write_bytes(b"")
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs", result.stderr)
        self.assertFalse(self.shared.exists())
        self.assertTrue((second / "b").is_file())

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

    def test_removed_source_skill_reports_broken_links_on_rerun(self):
        for home in self.homes:
            skill = home / "skills" / "same-name"
            skill.mkdir()
            (skill / "SKILL.md").write_text("initial")
        applied = self.run_tool("--apply")
        self.assertEqual(applied.returncode, 0, applied.stderr)
        shutil.rmtree(self.homes[0] / "skills" / "same-name")
        rerun = self.run_tool("--apply")
        self.assertNotEqual(rerun.returncode, 0)
        self.assertIn("broken skill link", rerun.stderr)
        self.assertFalse((self.shared / "same-name").exists())
        self.assertEqual(len(list((self.homes[1] / "skills").glob(
            ".same-name.before-sharing-*"))), 1)

    @unittest.skipIf(os.geteuid() == 0, "root can write mode 555 directories")
    def test_unwritable_copy_directory_refuses_before_shared_link(self):
        for home in self.homes:
            skill = home / "skills" / "same-name"
            skill.mkdir()
            (skill / "SKILL.md").write_text("initial")
        directory = self.homes[1] / "skills"
        directory.chmod(0o555)
        try:
            result = self.run_tool("--apply")
        finally:
            directory.chmod(0o755)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unwritable directory", result.stderr)
        self.assertFalse(self.shared.exists())
        self.assertTrue((directory / "same-name").is_dir())

    def test_late_copy_failure_rolls_back_earlier_unifications(self):
        third = self.root / "third"
        (third / "skills").mkdir(parents=True)
        for home in (*self.homes, third):
            skill = home / "skills" / "same-name"
            skill.mkdir()
            (skill / "SKILL.md").write_text("initial")
        spec = importlib.util.spec_from_file_location("share_codex_extensions", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        original_rename = Path.rename
        failing_copy = third / "skills" / "same-name"

        def refuse_late_rename(path, target):
            if path.resolve() == failing_copy.resolve():
                raise PermissionError("simulated late rename failure")
            return original_rename(path, target)

        arguments = [str(SCRIPT), *[item for home in (*self.homes, third)
                                    for item in ("--home", str(home))],
                     "--shared-skills", str(self.shared), "--codex-bin", str(self.cli),
                     "--apply"]
        with patch.dict(os.environ, {"HOME": str(self.root)}), \
                patch.object(sys, "argv", arguments), \
                patch.object(Path, "rename", refuse_late_rename), \
                redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(PermissionError, "simulated late rename"):
                module.main()
        self.assertFalse(self.shared.exists())
        for home in (*self.homes, third):
            copy = home / "skills" / "same-name"
            self.assertTrue(copy.is_dir())
            self.assertFalse(copy.is_symlink())
            self.assertEqual((copy / "SKILL.md").read_text(), "initial")
            self.assertEqual(list((home / "skills").glob(".same-name.before-sharing-*")), [])

    def test_custom_marketplace_is_added_before_plugin(self):
        market = self.root / "team"
        market.mkdir()
        manifest = market / ".agents" / "plugins" / "marketplace.json"
        manifest.parent.mkdir(parents=True)
        plugin_dir = market / "plugins" / "sample"
        plugin_dir.mkdir(parents=True)
        (plugin_dir / "plugin.json").write_text('{"name":"sample"}')
        manifest.write_text('{"name":"team","plugins":[{"name":"sample",'
                            '"source":{"source":"local","path":"./plugins/sample"},'
                            '"policy":{"installation":"AVAILABLE"}}]}')
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

    def test_local_marketplace_source_alias_is_idempotent(self):
        market = self.root / "team"
        manifest = market / ".agents" / "plugins" / "marketplace.json"
        manifest.parent.mkdir(parents=True)
        plugin_dir = market / "plugins" / "sample"
        plugin_dir.mkdir(parents=True)
        (plugin_dir / "plugin.json").write_text('{"name":"sample"}')
        manifest.write_text('{"name":"team","plugins":[{"name":"sample",'
                            '"source":{"source":"local","path":"./plugins/sample"},'
                            '"policy":{"installation":"AVAILABLE"}}]}')
        alias = self.root / "team-alias"
        alias.symlink_to(market, target_is_directory=True)
        (self.homes[0] / "config.toml").write_text(
            f'[marketplaces.team]\nsource_type = "local"\nsource = "{alias}"\n'
            '[plugins."sample@team"]\nenabled = true\n'
        )
        applied = self.run_tool("--apply")
        self.assertEqual(applied.returncode, 0, applied.stderr)
        rerun = self.run_tool()
        self.assertEqual(rerun.returncode, 0, rerun.stderr)
        self.assertIn("Marketplaces to add: 0", rerun.stdout)
        self.assertIn("Plugin installations: 0", rerun.stdout)

    def test_existing_cli_marketplace_same_source_is_reused(self):
        market = self.root / "team"
        manifest = market / ".agents" / "plugins" / "marketplace.json"
        manifest.parent.mkdir(parents=True)
        plugin_dir = market / "plugins" / "sample"
        plugin_dir.mkdir(parents=True)
        (plugin_dir / "plugin.json").write_text('{"name":"sample"}')
        manifest.write_text('{"name":"team","plugins":[{"name":"sample",'
                            '"source":{"source":"local","path":"./plugins/sample"},'
                            '"policy":{"installation":"AVAILABLE"}}]}')
        (self.homes[0] / "config.toml").write_text(
            f'[marketplaces.team]\nsource_type = "local"\nsource = "{market}"\n'
            '[plugins."sample@team"]\nenabled = true\n'
        )
        (self.homes[1] / ".implicit-marketplaces.json").write_text(
            f'{{"team":"{market}"}}'
        )
        applied = self.run_tool("--apply")
        self.assertEqual(applied.returncode, 0, applied.stderr)
        self.assertIn("Marketplaces to add: 0", applied.stdout)
        self.assertNotIn("[marketplaces.team]", (self.homes[1] / "config.toml").read_text())
        self.assertIn("Plugin installations: 0", self.run_tool().stdout)

    def test_existing_cli_marketplace_other_source_refuses_before_links(self):
        skill = self.homes[0] / "skills" / "source-skill"
        skill.mkdir()
        (skill / "SKILL.md").write_text("safe")
        market = self.root / "team"
        manifest = market / ".agents" / "plugins" / "marketplace.json"
        manifest.parent.mkdir(parents=True)
        plugin_dir = market / "plugins" / "sample"
        plugin_dir.mkdir(parents=True)
        (plugin_dir / "plugin.json").write_text('{"name":"sample"}')
        manifest.write_text('{"name":"team","plugins":[{"name":"sample",'
                            '"source":{"source":"local","path":"./plugins/sample"},'
                            '"policy":{"installation":"AVAILABLE"}}]}')
        (self.homes[0] / "config.toml").write_text(
            f'[marketplaces.team]\nsource_type = "local"\nsource = "{market}"\n'
            '[plugins."sample@team"]\nenabled = true\n'
        )
        (self.homes[1] / ".implicit-marketplaces.json").write_text(
            f'{{"team":"{self.root / "other-team"}"}}'
        )
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists from another or unknown source", result.stderr)
        self.assertFalse(self.shared.exists())
        self.assertFalse((self.homes[1] / "config.toml").exists())

    def test_configured_local_marketplace_requires_verified_cli_origin(self):
        skill = self.homes[0] / "skills" / "source-skill"
        skill.mkdir()
        (skill / "SKILL.md").write_text("safe")
        market = self.root / "team"
        manifest = market / ".agents" / "plugins" / "marketplace.json"
        manifest.parent.mkdir(parents=True)
        plugin_dir = market / "plugins" / "sample"
        plugin_dir.mkdir(parents=True)
        (plugin_dir / "plugin.json").write_text('{"name":"sample"}')
        manifest.write_text('{"name":"team","plugins":[{"name":"sample",'
                            '"source":{"source":"local","path":"./plugins/sample"},'
                            '"policy":{"installation":"AVAILABLE"}}]}')
        (self.homes[0] / "config.toml").write_text(
            f'[marketplaces.team]\nsource_type = "local"\nsource = "{market}"\n'
            '[plugins."sample@team"]\nenabled = true\n'
        )
        for origin in ("git", "missing"):
            with self.subTest(origin=origin):
                if origin == "git":
                    (self.homes[0] / ".marketplace-origin-overrides.json").write_text(
                        '{"team":{"sourceType":"git","source":"owner/other-market"}}'
                    )
                else:
                    (self.homes[0] / ".marketplace-origin-overrides.json").unlink()
                    (self.homes[0] / ".omit-marketplaces").write_text("team\n")
                result = self.run_tool("--apply")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("different or unknown source", result.stderr)
                self.assertFalse(self.shared.exists())
                self.assertFalse((self.homes[1] / "config.toml").exists())

    def test_missing_local_plugin_source_refuses_before_links(self):
        skill = self.homes[0] / "skills" / "source-skill"
        skill.mkdir()
        (skill / "SKILL.md").write_text("safe")
        market = self.root / "team"
        manifest = market / ".agents" / "plugins" / "marketplace.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text('{"name":"team","plugins":[{"name":"sample",'
                            '"source":"./missing",'
                            '"policy":{"installation":"AVAILABLE"}}]}')
        (self.homes[0] / "config.toml").write_text(
            f'[marketplaces.team]\nsource_type = "local"\nsource = "{market}"\n'
            '[plugins."sample@team"]\nenabled = true\n'
        )
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("local source is missing", result.stderr)
        self.assertFalse(self.shared.exists())
        self.assertFalse((self.homes[1] / "config.toml").exists())

    def test_wrong_local_plugin_manifest_refuses_before_links(self):
        skill = self.homes[0] / "skills" / "source-skill"
        skill.mkdir()
        (skill / "SKILL.md").write_text("safe")
        market = self.root / "team"
        manifest = market / ".agents" / "plugins" / "marketplace.json"
        manifest.parent.mkdir(parents=True)
        plugin_dir = market / "plugins" / "sample"
        plugin_dir.mkdir(parents=True)
        (plugin_dir / "plugin.json").write_text('{"name":"other"}')
        manifest.write_text('{"name":"team","plugins":[{"name":"sample",'
                            '"source":{"source":"local","path":"./plugins/sample"},'
                            '"policy":{"installation":"AVAILABLE"}}]}')
        (self.homes[0] / "config.toml").write_text(
            f'[marketplaces.team]\nsource_type = "local"\nsource = "{market}"\n'
            '[plugins."sample@team"]\nenabled = true\n'
        )
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not named 'sample'", result.stderr)
        self.assertFalse(self.shared.exists())

    def test_not_installable_local_marketplace_refuses_before_skill_links(self):
        skill = self.homes[0] / "skills" / "source-skill"
        skill.mkdir()
        (skill / "SKILL.md").write_text("safe")
        market = self.root / "team"
        manifest = market / ".agents" / "plugins" / "marketplace.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text('{"name":"team","plugins":[{"name":"sample",'
                            '"policy":{"installation":"NOT_AVAILABLE"}}]}')
        (self.homes[0] / "config.toml").write_text(
            f'[marketplaces.team]\nsource_type = "local"\nsource = "{market}"\n'
            '[plugins."sample@team"]\nenabled = true\n'
        )
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not installable in local marketplace", result.stderr)
        self.assertFalse(self.shared.exists())
        self.assertFalse((self.homes[1] / "config.toml").exists())

    def test_invalid_local_marketplace_refuses_before_skill_links(self):
        skill = self.homes[0] / "skills" / "source-skill"
        skill.mkdir()
        (skill / "SKILL.md").write_text("safe")
        (self.homes[0] / "config.toml").write_text(
            f'[marketplaces.team]\nsource_type = "local"\nsource = "{self.root / "missing"}"\n'
            '[plugins."sample@team"]\nenabled = true\n'
        )
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot read local marketplace", result.stderr)
        self.assertFalse(self.shared.exists())

    def test_case_insensitive_skill_collision_refuses_before_changes(self):
        for home, name in zip(self.homes, ("Alpha", "alpha")):
            skill = home / "skills" / name
            skill.mkdir()
            (skill / "SKILL.md").write_text("safe")
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("case-insensitive", result.stderr)
        self.assertFalse(self.shared.exists())

    def test_skill_change_during_plugin_preflight_refuses_before_links(self):
        for home in self.homes:
            skill = home / "skills" / "same-name"
            skill.mkdir()
            (skill / "SKILL.md").write_text("initial")
        first_skill = self.homes[0] / "skills" / "same-name" / "SKILL.md"
        result = self.run_tool("--apply", env={"FAKE_CODEX_MUTATE_SKILL": str(first_skill)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed during plugin preflight", result.stderr)
        self.assertFalse(self.shared.exists())
        self.assertFalse((self.homes[1] / "skills" / "same-name").is_symlink())

    def test_singleton_skill_with_external_link_refuses_before_changes(self):
        skill = self.homes[0] / "skills" / "source-skill"
        skill.mkdir()
        (skill / "SKILL.md").write_text("safe")
        private = self.homes[0] / "auth.json"
        private.write_text("secret")
        (skill / "resource").symlink_to(private)
        result = self.run_tool("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("escapes its directory", result.stderr)
        self.assertFalse(self.shared.exists())

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
            capture_output=True, text=True, env={**os.environ, "HOME": str(self.root)},
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

    def test_non_discovery_shared_directory_is_rejected(self):
        for home in self.homes:
            skill = home / "skills" / "demo"
            skill.mkdir()
            (skill / "SKILL.md").write_text("same")
        nested = self.homes[0] / "skills" / "demo" / "shared"
        result = subprocess.run(
            [sys.executable, str(SCRIPT),
             *[item for home in self.homes for item in ("--home", str(home))],
             "--shared-skills", str(nested), "--codex-bin", str(self.cli), "--apply"],
            capture_output=True, text=True, env={**os.environ, "HOME": str(self.root)},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("user discovery directory", result.stderr)
        self.assertFalse(nested.exists())


if __name__ == "__main__":
    unittest.main()
