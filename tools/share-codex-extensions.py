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


def die(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def skill_digest(directory: Path) -> str:
    """Compare the complete skill, including scripts and other resources."""
    digest = hashlib.sha256()
    for root, dirs, files in os.walk(directory, followlinks=False):
        dirs.sort()
        for name in sorted(dirs + files):
            path = Path(root) / name
            relative = path.relative_to(directory).as_posix()
            digest.update(relative.encode())
            if path.is_symlink():
                digest.update(b"link\0" + os.readlink(path).encode())
            elif path.is_file():
                digest.update(b"file\0" + path.read_bytes())
            elif path.is_dir():
                digest.update(b"dir\0")
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


def enabled_plugins(home: Path) -> set[str]:
    config = home / "config.toml"
    if not config.is_file():
        return set()
    try:
        data = tomllib.loads(config.read_text())
    except (OSError, ValueError) as error:
        die(f"cannot parse {config}: {error}")
    plugins = data.get("plugins", {})
    if not isinstance(plugins, dict):
        die(f"[plugins] is not a table in {config}")
    return {
        name for name, settings in plugins.items()
        if isinstance(settings, dict) and settings.get("enabled") is True
    }


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

    sources: dict[str, Path] = {}
    for home in homes:
        for name, path in user_skills(home).items():
            if name in sources and skill_digest(sources[name]) != skill_digest(path):
                die(f"skill {name!r} differs between {sources[name]} and {path}; resolve it first")
            sources.setdefault(name, path)

    links: list[tuple[str, Path]] = []
    for name, source in sorted(sources.items()):
        target = shared / name
        if target.is_symlink() and not target.exists():
            die(f"broken shared skill link: {target}")
        if target.exists():
            if not (target / "SKILL.md").is_file():
                die(f"existing shared entry is not a skill: {target}")
            if skill_digest(target) != skill_digest(source):
                die(f"shared skill {target} differs from {source}; resolve it first")
        else:
            links.append((name, source))

    current = {home: enabled_plugins(home) for home in homes}
    desired = set().union(*current.values())
    installs = [(home, plugin) for home in homes for plugin in sorted(desired - current[home])]

    print("Homes:")
    for home in homes:
        print(f"  {home}")
    print(f"Shared skills: {shared}")
    print(f"Skill links to create: {len(links)}")
    for name, source in links:
        print(f"  {name}: {shared / name} -> {source}")
    print(f"Plugin installations: {len(installs)}")
    for home, plugin in installs:
        print(f"  {home}: {plugin}")
    if not args.apply:
        print("Plan only; pass --apply to make these changes.")
        return

    codex = shutil.which(args.codex_bin)
    if installs and codex is None:
        die(f"Codex CLI not found: {args.codex_bin}")
    if links:
        shared.mkdir(parents=True, exist_ok=True)
    for name, source in links:
        target = shared / name
        if target.exists() or target.is_symlink():
            die(f"shared skill appeared during apply: {target}")
        target.symlink_to(source, target_is_directory=True)
        print(f"Linked skill: {name}")

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
