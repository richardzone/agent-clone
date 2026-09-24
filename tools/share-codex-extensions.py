#!/usr/bin/env python3
"""Share user skills and enabled plugins across explicit Codex homes.

No profile is inferred from this repository. The default mode only prints a plan.
"""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tomllib
import uuid


def die(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def skill_digest(directory: Path) -> str:
    """Compare the complete skill, including scripts and other resources."""
    digest = hashlib.sha256()
    skill_root = directory.resolve(strict=True)
    digest.update(str(skill_root.stat().st_mode & 0o777).encode() + b"\0")
    for root, dirs, files in os.walk(directory, followlinks=False):
        dirs.sort()
        for name in sorted(dirs + files):
            path = Path(root) / name
            relative = path.relative_to(directory).as_posix()
            digest.update(relative.encode())
            if path.is_symlink():
                try:
                    resolved = path.resolve(strict=True)
                except (OSError, RuntimeError) as error:
                    die(f"cannot resolve link in skill {path}: {error}")
                if not resolved.is_relative_to(skill_root):
                    die(f"skill link escapes its directory: {path}")
                digest.update(b"link\0" + os.readlink(path).encode())
            elif path.is_file():
                digest.update(b"file\0" + str(path.stat().st_mode & 0o777).encode()
                              + b"\0" + path.read_bytes())
            elif path.is_dir():
                digest.update(b"dir\0" + str(path.stat().st_mode & 0o777).encode())
            else:
                die(f"unsupported entry in skill: {path}")
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

    links: list[tuple[str, Path]] = []
    redundant: list[tuple[str, Path]] = []
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
            links.append((name, source))

        canonical = target if target.exists() else source
        redundant += [(name, copy) for copy in copies
                      if copy.resolve() != canonical.resolve()]

    current = {home: enabled_plugins(home) for home in homes}
    desired = set().union(*current.values())
    installs = [(home, plugin) for home in homes for plugin in sorted(desired - current[home])]
    configured_markets = {home: marketplaces(home) for home in homes}
    market_additions: dict[tuple[Path, str], dict] = {}
    builtin_markets = {"openai-bundled", "openai-primary-runtime"}
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

    codex = shutil.which(args.codex_bin)
    if (installs or market_additions) and codex is None:
        die(f"Codex CLI not found: {args.codex_bin}")
    if links:
        shared.mkdir(parents=True, exist_ok=True)
    for name, source in links:
        target = shared / name
        if target.exists() or target.is_symlink():
            die(f"shared skill appeared during apply: {target}")
        target.symlink_to(source, target_is_directory=True)
        print(f"Linked skill: {name}")

    for name, copy in redundant:
        target = shared / name
        if skill_digest(copy) != skill_digest(target):
            die(f"skill changed during apply: {copy}")
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
        if result.returncode or plugin not in enabled_plugins(home):
            failed.append((home, plugin))
            print(f"FAILED plugin install: {plugin} in {home}", file=sys.stderr)
        else:
            print(f"Installed plugin: {plugin} in {home}")
    if failed:
        die(f"{len(failed)} plugin installation(s) failed; successful changes remain in place")
    print("Done. Open a new task in each Codex instance to verify the skills and plugins.")


if __name__ == "__main__":
    main()
