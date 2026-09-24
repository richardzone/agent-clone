#!/usr/bin/env python3
"""Share user skills and enabled plugins across explicit Codex homes.

No profile is inferred from this repository. The default mode does not apply changes.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tomllib
import unicodedata
import uuid


INSTALLABLE_POLICIES = {"AVAILABLE", "INSTALLED_BY_DEFAULT"}


def die(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def skill_digest(directory: Path) -> str:
    """Compare the complete skill, including scripts and other resources."""
    digest = hashlib.sha256()
    skill_root = directory.resolve(strict=True)
    digest.update(json.dumps(["root", skill_root.stat().st_mode & 0o777],
                             separators=(",", ":")).encode() + b"\n")

    def walk_error(error: OSError) -> None:
        die(f"cannot read skill directory {error.filename}: {error.strerror}")

    for root, dirs, files in os.walk(directory, followlinks=False, onerror=walk_error):
        dirs.sort()
        for name in sorted(dirs + files):
            path = Path(root) / name
            relative = path.relative_to(directory).as_posix()
            if path.is_symlink():
                try:
                    resolved = path.resolve(strict=True)
                except (OSError, RuntimeError) as error:
                    die(f"cannot resolve link in skill {path}: {error}")
                if not resolved.is_relative_to(skill_root):
                    die(f"skill link escapes its directory: {path}")
                kind, mode, payload = "link", None, os.readlink(path)
            elif path.is_file():
                kind = "file"
                mode = path.stat().st_mode & 0o777
                payload = hashlib.sha256(path.read_bytes()).hexdigest()
            elif path.is_dir():
                kind, mode, payload = "dir", path.stat().st_mode & 0o777, None
            else:
                die(f"unsupported entry in skill: {path}")
            digest.update(json.dumps([relative, kind, mode, payload],
                                     ensure_ascii=True, separators=(",", ":")).encode() + b"\n")
    return digest.hexdigest()


def user_skills(home: Path) -> dict[str, Path]:
    directory = home / "skills"
    if not directory.is_dir():
        return {}
    return {
        path.name: path
        for path in sorted(directory.iterdir())
        if not path.name.startswith((".", "_")) and (path / "SKILL.md").is_file()
    }


def codex_config(home: Path) -> dict:
    config = home / "config.toml"
    if not config.is_file():
        return {}
    try:
        return tomllib.loads(config.read_text())
    except (OSError, ValueError) as error:
        die(f"cannot parse {config}: {error}")


def enabled_plugins(home: Path) -> set[str]:
    data = codex_config(home)
    plugins = data.get("plugins", {})
    if not isinstance(plugins, dict):
        die(f"[plugins] is not a table in {home / 'config.toml'}")
    return {
        name for name, settings in plugins.items()
        if isinstance(settings, dict) and settings.get("enabled") is True
    }


def marketplaces(home: Path) -> dict:
    entries = codex_config(home).get("marketplaces", {})
    if not isinstance(entries, dict):
        die(f"[marketplaces] is not a table in {home / 'config.toml'}")
    return entries


def cli_json(codex: str, home: Path, command: list[str]) -> dict:
    env = os.environ.copy()
    env["CODEX_HOME"] = str(home)
    try:
        result = subprocess.run([codex, "plugin", *command, "--json"], env=env,
                                stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        die(f"cannot query Codex plugins in {home}: {error}")
    if result.returncode:
        die(f"Codex plugin query failed in {home}: plugin {' '.join(command)}")
    try:
        data = json.loads(result.stdout)
    except ValueError as error:
        die(f"invalid Codex plugin JSON in {home}: {error}")
    if not isinstance(data, dict):
        die(f"invalid Codex plugin response in {home}: expected an object")
    return data


def plugin_inventory(codex: str, home: Path) -> tuple[set[str], set[str]]:
    data = cli_json(codex, home, ["list", "--available"])
    installed, available = data.get("installed"), data.get("available")
    if not isinstance(installed, list) or not isinstance(available, list):
        die(f"invalid Codex plugin list in {home}: missing installed or available array")
    if any(not isinstance(item, dict) or not isinstance(item.get("pluginId"), str)
           for item in installed + available):
        die(f"invalid plugin entry in {home}")
    active = {item["pluginId"] for item in installed
              if item.get("installed") is True and item.get("enabled") is True}
    installable = {item["pluginId"] for item in installed + available
                   if item.get("installPolicy") in INSTALLABLE_POLICIES}
    return active, installable


def active_plugins(codex: str, home: Path) -> set[str]:
    return plugin_inventory(codex, home)[0]


def listed_marketplaces(codex: str, home: Path) -> set[str]:
    entries = cli_json(codex, home, ["marketplace", "list"]).get("marketplaces")
    if not isinstance(entries, list):
        die(f"invalid Codex marketplace list in {home}: missing marketplaces array")
    if any(not isinstance(item, dict) or not isinstance(item.get("name"), str)
           for item in entries):
        die(f"invalid marketplace entry in {home}")
    return {item["name"] for item in entries}


def marketplace_add_args(name: str, spec: dict) -> list[str]:
    source = spec.get("source")
    kind = spec.get("source_type")
    if not isinstance(source, str) or not source or kind not in ("local", "git"):
        die(f"unsupported marketplace definition for {name!r}; configure it manually")
    args = ["plugin", "marketplace", "add", source]
    if kind == "git":
        ref = spec.get("ref")
        if ref:
            if not isinstance(ref, str):
                die(f"invalid ref for marketplace {name!r}")
            args += ["--ref", ref]
        sparse = spec.get("sparse_paths", [])
        if not isinstance(sparse, list) or not all(isinstance(p, str) for p in sparse):
            die(f"invalid sparse paths for marketplace {name!r}")
        for path in sparse:
            args += ["--sparse", path]
    return args


def validate_local_marketplace(name: str, spec: dict, plugin: str) -> None:
    if spec.get("source_type") != "local":
        return
    manifest = Path(spec["source"]).expanduser() / ".agents" / "plugins" / "marketplace.json"
    try:
        data = json.loads(manifest.read_text())
    except (OSError, ValueError) as error:
        die(f"cannot read local marketplace {name!r} at {manifest}: {error}")
    if not isinstance(data, dict) or data.get("name") != name:
        die(f"local marketplace at {manifest} is not named {name!r}")
    entries = data.get("plugins")
    plugin_name = plugin.rsplit("@", 1)[0]
    if not isinstance(entries, list):
        die(f"local marketplace at {manifest} has no plugin list")
    matches = [entry for entry in entries
               if isinstance(entry, dict) and entry.get("name") == plugin_name]
    if len(matches) != 1 or not isinstance(matches[0].get("policy"), dict):
        die(f"plugin {plugin!r} is missing or ambiguous in local marketplace {manifest}")
    if matches[0]["policy"].get("installation") not in INSTALLABLE_POLICIES:
        die(f"plugin {plugin!r} is not installable in local marketplace {manifest}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", action="append", required=True, type=Path,
                        help="Codex home to reconcile; repeat for each instance")
    parser.add_argument("--shared-skills", type=Path,
                        default=Path.home() / ".agents" / "skills",
                        help="shared discovery directory (default: ~/.agents/skills)")
    parser.add_argument("--codex-bin", default="codex",
                        help="Codex CLI used for official plugin installation")
    parser.add_argument("--apply", action="store_true",
                        help="create skill links and install missing plugins")
    args = parser.parse_args()

    try:
        homes = [path.expanduser().resolve(strict=True) for path in args.home]
    except (OSError, RuntimeError) as error:
        die(f"cannot resolve a Codex home: {error}")
    if len(homes) < 2 or len(set(homes)) != len(homes):
        die("provide at least two distinct --home paths")
    if any(not home.is_dir() for home in homes):
        die("every --home must be a directory")
    shared = args.shared_skills.expanduser().absolute()
    discovery = (Path.home() / ".agents" / "skills").absolute()
    if shared.resolve() != discovery.resolve():
        die(f"shared skills path must be Codex's user discovery directory: {discovery}")
    if shared.is_symlink():
        die(f"shared skills directory must not be a symlink: {shared}")
    if shared.exists() and not shared.is_dir():
        die(f"shared skills path is not a directory: {shared}")

    sources: dict[str, list[Path]] = {}
    for home in homes:
        for name, path in user_skills(home).items():
            if shared.resolve().is_relative_to(path.resolve()):
                die(f"shared skills directory is inside source skill: {shared} in {path}")
            if (name in sources and sources[name][0].resolve() != path.resolve()
                    and skill_digest(sources[name][0]) != skill_digest(path)):
                die(f"skill {name!r} differs between {sources[name][0]} and {path}; resolve it first")
            sources.setdefault(name, []).append(path)

    folded_names: dict[str, str] = {}
    for name in sources:
        folded = unicodedata.normalize("NFD", name).casefold()
        if folded in folded_names and folded_names[folded] != name:
            die(f"skill names collide on a case-insensitive filesystem: "
                f"{folded_names[folded]!r} and {name!r}")
        folded_names[folded] = name
    if shared.is_dir():
        for entry in shared.iterdir():
            folded = unicodedata.normalize("NFD", entry.name).casefold()
            if folded in folded_names and folded_names[folded] != entry.name:
                die(f"shared skill name {entry.name!r} collides with "
                    f"{folded_names[folded]!r}")

    links: list[tuple[str, Path]] = []
    redundant: list[tuple[str, Path]] = []
    link_digests: dict[str, str] = {}
    for name, copies in sorted(sources.items()):
        source = copies[0]
        target = shared / name
        if target.is_symlink() and not target.exists():
            die(f"broken shared skill link: {target}")
        if target.exists():
            if not (target / "SKILL.md").is_file():
                die(f"existing shared entry is not a skill: {target}")
            if target.resolve() != source.resolve() and skill_digest(target) != skill_digest(source):
                die(f"shared skill {target} differs from {source}; resolve it first")
        else:
            link_digests[name] = skill_digest(source)
            links.append((name, source))

        canonical = target if target.exists() else source
        redundant += [(name, copy) for copy in copies
                      if copy.resolve() != canonical.resolve()]
    redundant_digests = {(name, copy): skill_digest(copy) for name, copy in redundant}
    target_digests = {name: skill_digest(shared / name) for name, _ in redundant
                      if (shared / name).exists()}

    codex = shutil.which(args.codex_bin)
    if codex is None:
        die(f"Codex CLI not found: {args.codex_bin}")
    inventory = {home: plugin_inventory(codex, home) for home in homes}
    installed = {home: inventory[home][0] for home in homes}
    installable = {home: inventory[home][1] for home in homes}
    current = {home: enabled_plugins(home) | installed[home] for home in homes}
    desired = set().union(*current.values())
    installs = [(home, plugin) for home in homes for plugin in sorted(desired - installed[home])]
    configured_markets = {home: marketplaces(home) for home in homes}
    market_additions: dict[tuple[Path, str], dict] = {}
    builtin_markets = {"openai-bundled", "openai-primary-runtime"}
    if any(plugin.rsplit("@", 1)[-1] in builtin_markets for plugin in desired):
        builtin_available = {home: listed_marketplaces(codex, home) for home in homes}
        for home, plugin in installs:
            market = plugin.rsplit("@", 1)[-1]
            if market in builtin_markets and market not in builtin_available[home]:
                die(f"built-in marketplace {market!r} is unavailable in {home}; "
                    "initialize that Codex home and retry before applying changes")
    market_specs: dict[str, dict] = {}
    for plugin in sorted(desired):
        if "@" not in plugin:
            die(f"plugin ID lacks a marketplace: {plugin!r}")
        market = plugin.rsplit("@", 1)[1]
        if market in builtin_markets:
            continue
        definitions = [(source, configured_markets[source][market]) for source in homes
                       if market in configured_markets[source]]
        if not definitions:
            continue  # Account-level marketplace; let Codex resolve it.
        spec = definitions[0][1]
        for source_home, other in definitions:
            if not isinstance(other, dict):
                die(f"invalid marketplace {market!r} in {source_home / 'config.toml'}")
            if other != spec:
                die(f"marketplace {market!r} has conflicting sources in {definitions[0][0]} and {source_home}")
        if any(plugin in current[source] and market not in configured_markets[source]
               for source in homes):
            die(f"cannot verify marketplace {market!r} for every source of {plugin!r}")
        marketplace_add_args(market, spec)  # Validate before making any changes.
        if any(plugin in desired - installed[home] for home in homes):
            validate_local_marketplace(market, spec, plugin)
            if not any(plugin in installable[source_home] for source_home, _ in definitions):
                die(f"plugin {plugin!r} is not installable in its source marketplace")
        market_specs[market] = spec

    for home, plugin in installs:
        market = plugin.rsplit("@", 1)[1]
        spec = market_specs.get(market)
        if spec is None:
            continue  # Built-in or account-level marketplace; let Codex resolve it.
        if market in configured_markets[home]:
            continue
        key = (home, market)
        market_additions[key] = spec

    for home, plugin in installs:
        market = plugin.rsplit("@", 1)[1]
        if (home, market) not in market_additions and plugin not in installable[home]:
            die(f"plugin {plugin!r} is unavailable or not installable in {home}; "
                "configure its marketplace or sign in to its account-level catalog "
                "before applying changes")

    print("Homes:")
    for home in homes:
        print(f"  {home}")
    print(f"Shared skills: {shared}")
    print(f"Skill links to create: {len(links)}")
    for name, source in links:
        print(f"  {name}: {shared / name} -> {source}")
    print(f"Local skill copies to unify: {len(redundant)}")
    for name, copy in redundant:
        print(f"  {copy} -> {shared / name} (original kept as a hidden backup)")
    print(f"Marketplaces to add: {len(market_additions)}")
    for home, market in market_additions:
        print(f"  {home}: {market}")
    print(f"Plugin installations: {len(installs)}")
    for home, plugin in installs:
        print(f"  {home}: {plugin}")
    if not args.apply:
        print("Plan only; pass --apply to make these changes.")
        return

    # CLI inventory calls may take time. Reject changed inputs before the first write.
    for name, source in links:
        if skill_digest(source) != link_digests[name]:
            die(f"skill changed during plugin preflight: {source}")
    for (name, copy), digest in redundant_digests.items():
        if skill_digest(copy) != digest:
            die(f"skill changed during plugin preflight: {copy}")
    for name, digest in target_digests.items():
        if skill_digest(shared / name) != digest:
            die(f"shared skill changed during plugin preflight: {shared / name}")

    created_links: list[tuple[Path, Path]] = []
    created_shared = bool(links) and not shared.exists()
    try:
        if links:
            shared.mkdir(parents=True, exist_ok=True)
        for name, source in links:
            target = shared / name
            if target.exists() or target.is_symlink():
                die(f"shared skill appeared during apply: {target}")
            target.symlink_to(source, target_is_directory=True)
            created_links.append((target, source))

        # Check the whole unification batch before renaming any original copy.
        for (name, copy), digest in redundant_digests.items():
            if skill_digest(copy) != digest or skill_digest(shared / name) != digest:
                die(f"skill changed during apply: {copy}")
    except BaseException:
        for target, source in reversed(created_links):
            if target.is_symlink() and target.readlink() == source:
                target.unlink()
        if created_shared:
            try:
                shared.rmdir()
            except OSError:
                pass
        raise

    for name, _ in links:
        print(f"Linked skill: {name}")

    for name, copy in redundant:
        target = shared / name
        backup = copy.with_name(f".{name}.before-sharing-{uuid.uuid4().hex[:12]}")
        copy.rename(backup)
        try:
            copy.symlink_to(target, target_is_directory=True)
        except OSError:
            backup.rename(copy)
            raise
        print(f"Unified skill: {name} in {copy.parent}; backup: {backup}")

    for (home, market), spec in market_additions.items():
        env = os.environ.copy()
        env["CODEX_HOME"] = str(home)
        command = [codex, *marketplace_add_args(market, spec)]
        result = subprocess.run(command, env=env, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True)
        if result.returncode or market not in marketplaces(home):
            die(f"could not add marketplace {market!r} to {home}; successful changes remain")
        print(f"Added marketplace: {market} to {home}")

    failed = []
    for home, plugin in installs:
        env = os.environ.copy()
        env["CODEX_HOME"] = str(home)
        result = subprocess.run([codex, "plugin", "add", plugin], env=env,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True)
        if result.returncode or plugin not in active_plugins(codex, home):
            failed.append((home, plugin))
            print(f"FAILED plugin install: {plugin} in {home}", file=sys.stderr)
        else:
            print(f"Installed plugin: {plugin} in {home}")
    if failed:
        die(f"{len(failed)} plugin installation(s) failed; successful changes remain in place")
    for home in homes:
        missing = desired - active_plugins(codex, home)
        if missing:
            die(f"{len(missing)} desired plugin(s) are not active in {home}; "
                "successful changes remain in place")
    print("Done. Open a new task in each Codex instance to verify the skills and plugins.")


if __name__ == "__main__":
    main()
