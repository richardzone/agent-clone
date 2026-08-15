#!/bin/zsh
# Adapter: Claude desktop (Anthropic)
#
# Loaded by clone-agent.sh. Interface contract: adapters/README.md.

A_LABEL="Claude"
A_SOURCE_DEFAULT="/Applications/Claude.app"
A_EXEC_NAME="Claude"                                  # original executable under Contents/MacOS/
A_BUNDLE_ID_BASE="com.anthropic.claudefordesktop"
A_FRAMEWORK=""                                        # main framework name; empty = nothing special
A_CLI_COMMAND="claude"
A_CLI_HOME_TEMPLATE='$HOME/.claude-<NAME>'
# Namespaces the generated launcher clears before setting anything. Deliberately
# CLAUDE_* rather than CLAUDE_CODE_*: the identity-relevant variables are spread
# across both. CLAUDE_SECURESTORAGE_CONFIG_DIR is the reason it matters — Claude
# Code suffixes its keychain service name with a hash of the secure-storage
# directory, and falls back to CLAUDE_CONFIG_DIR only while that variable is
# *undefined*. An ambient empty value drops the suffix entirely and re-points the
# profile at the default account's entry, so clearing it is what preserves
# per-profile keychain isolation; nothing needs to re-set it afterwards.
A_CLI_ENV_NAMESPACES=('ANTHROPIC_*' 'CLAUDE_*')

# Claude's keychain service name derives from productName in the asar's
# package.json, so changing productName yields a separate "<Name> Safe Storage"
# entry — full isolation.
A_KEYCHAIN_ISOLATED=1

# ⚠️ Claude Desktop's built-in Claude Code reads ~/.claude — the same directory as
# the original app and the CLI, and --user-data-dir does not cover it. So Claude
# Code's settings, sessions, history and plugins ARE shared between a clone and the
# original. That is deliberate here, not an oversight: it is usually what you want,
# since it keeps one set of skills, plugins and settings across both.
# CLAUDE_CONFIG_DIR would split them (the app resolves the config root as
# `CLAUDE_CONFIG_DIR ?? ~/.claude`), but injecting it is a one-way move — sessions
# written afterwards land in the new directory and cannot be merged back cleanly.
# Don't add it here without the user explicitly asking for split config.

# Where the app looks for its local-tier policy file. Derived from userData, which
# the engine isolates via --user-data-dir, so this is already per-clone:
#   Lf() = CLAUDE_USER_DATA_DIR ? userData : userData + "-3p"
# The managed tier is no use to us here — its path is the hard-coded bundle ID
# /Library/Managed Preferences/com.anthropic.claudefordesktop.plist, shared with
# the original, so a policy deployed there would stop the original updating too.
A_POLICY_ROOT_SUFFIX="-3p"

# The two hard-coded managed-tier paths. Their mere presence matters: see
# a_post_install, which warns when either exists.
A_MANAGED_PLIST="/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
A_MANAGED_PLIST_USER="/Library/Managed Preferences/${USER}/com.anthropic.claudefordesktop.plist"

# Resolve the policy root the same way the app does. Note the guard: Lf() is
#   e.endsWith("-3p") ? e : e + "-3p"
# so a clone whose data directory already ends in -3p (a clone literally named
# "Work-3p", which this repo's own docs now make a plausible choice) must NOT get a
# second suffix, or we would write to <name>-3p-3p while the app reads <name>-3p.
_a_policy_root() {
  local data_dir="$1"
  if [[ "$data_dir" == *${A_POLICY_ROOT_SUFFIX} ]]; then
    print "$data_dir"
  else
    print "${data_dir}${A_POLICY_ROOT_SUFFIX}"
  fi
}

a_preflight() {
  local src="$1"
  local suffix
  # Electron builds helper paths from the main app's CFBundleName, so the helpers
  # must exist and be named predictably.
  for suffix in "" " (GPU)" " (Plugin)" " (Renderer)"; do
    [[ -d "$src/Contents/Frameworks/Claude Helper${suffix}.app" ]] ||
      { print "Missing helper 'Claude Helper${suffix}.app' — Electron helper naming may have changed"; return 1 }
  done
  print "   Helper naming ✓ (4 found)"
  # What a_post_install depends on: the policy key itself, and the directory layout
  # it gets written into. If upstream renames either, the clone would silently
  # resume hourly update downloads, so fail loudly here instead.
  # grep -qa reads the asar directly rather than piping through `strings`: one less
  # dependency (strings ships with the Command Line Tools, and when it is missing
  # the pipe reports "key gone" — an upstream change that never happened), and it
  # is an order of magnitude faster since grep stops at the first match.
  local asar="$src/Contents/Resources/app.asar"
  if ! grep -qa 'disableAutoUpdates' "$asar"; then
    print "disableAutoUpdates not found in app.asar — the auto-update policy key is gone"; return 1
  fi
  print "   disableAutoUpdates policy key ✓"
  if ! grep -qa 'configLibrary' "$asar"; then
    print "configLibrary not found in app.asar — the local-tier layout has changed"; return 1
  fi
  print "   configLibrary layout ✓"
  # ⚠️ Not covered: the "-3p" in A_POLICY_ROOT_SUFFIX. It is built at runtime
  # (`${appName}${suffix}`), so no literal to grep for — searching for "-3p" alone
  # matches ~60 unrelated strings (chunk filenames, "custom-3p", …) and would pass
  # even if the real suffix changed. Checklist item 7 in AGENTS.md is what catches
  # that: after a rebuild, confirm the log actually says auto-updates are disabled.
}

a_rename_helpers() {
  local app="$1" name="$2"
  # Electron locates helpers via the main app's CFBundleName:
  #   Contents/Frameworks/<CFBundleName> Helper.app
  # Skipping this yields FATAL: Unable to find helper app.
  # Three things must change together: the bundle directory name, the inner
  # executable name, and CFBundleExecutable.
  local fw="$app/Contents/Frameworks" suffix old new hp
  for suffix in "" " (GPU)" " (Plugin)" " (Renderer)"; do
    old="$fw/Claude Helper${suffix}.app"
    new="$fw/${name} Helper${suffix}.app"
    mv "$old" "$new"
    mv "$new/Contents/MacOS/Claude Helper${suffix}" "$new/Contents/MacOS/${name} Helper${suffix}"
    hp="$new/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable '${name} Helper${suffix}'" "$hp"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName '${name} Helper${suffix}'" "$hp" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName '${name} Helper${suffix}'" "$hp" 2>/dev/null || true
    print "   ${name} Helper${suffix}.app"
  done
}

# Claude's updater has no Info.plist switch; it is disabled through the local-tier
# policy file written by a_post_install instead.
a_extra_plist() { :; }

a_wrapper_env() {
  # Scrub, don't set. CLAUDE_USER_DATA_DIR flips the app onto the other branch of
  # Lf() — it then uses userData unsuffixed, so the policy file this adapter writes
  # to <userData>-3p is never read and auto-updates quietly resume, with preflight
  # still reporting ✓. Inheriting it from the user's shell is enough to trigger
  # that, so clear it here; unsetting also makes A_POLICY_ROOT_SUFFIX
  # unconditionally correct rather than correct-unless-the-environment-says-otherwise.
  print 'unset CLAUDE_USER_DATA_DIR'
  # Deliberately NOT setting CLAUDE_CONFIG_DIR — see the note at the top of this file.
}

a_cli_preflight() { :; }

# The engine has already cleared A_CLI_ENV_NAMESPACES by the time this runs, so
# the profile's own directory is the only thing left to establish. Per-profile
# tuning belongs in that directory's settings.json, which is isolated with it —
# not in ambient environment variables, which are not.
a_cli_wrapper_env() {
  local name="$1"
  print "export CLAUDE_CONFIG_DIR=\"${A_CLI_HOME_TEMPLATE//<NAME>/$name}\""
}

# $agent_cli is resolved by the engine on the lines just above this one: the path
# pinned at preflight, or a PATH lookup if a runtime manager has since moved it.
a_cli_exec() { print 'exec "$agent_cli" "$@"'; }

a_sign_extra() {
  local app="$1" h f
  # Contents of Helpers/ vary by release (1.28929 added app-cu-helper), so don't
  # hard-code the names.
  for h in "$app/Contents/Helpers/"*.app; do
    [[ -d "$h" ]] && codesign --force --sign - "$h" >/dev/null 2>&1
  done
  for f in "$app/Contents/Helpers/"*; do
    [[ -f "$f" ]] && codesign --force --sign - "$f" >/dev/null 2>&1
  done
}

a_post_install() {
  local name="$1" data_dir="$2"
  # Turn off auto-updates through the app's own policy key. Claude's updater has no
  # Info.plist switch, but `disableAutoUpdates` (available since 1.2581.0) is read
  # from the local tier, which lives under the clone's own data directory — so this
  # stops the clone checking without touching the original.
  # Without it the clone downloads a full installer every hour and fails to apply it
  # ("Could not locate update bundle", the bundle ID no longer matches), which is
  # harmless but pure wasted bandwidth.
  node "$REPO_DIR/tools/write-config-library.js" \
    "$(_a_policy_root "$data_dir")/configLibrary" '{"disableAutoUpdates":true}' || return 1

  # The local tier only wins while the managed tier is unusable. The precedence is
  # coarser than it looks: the app discards the local tier whole as soon as the
  # managed plist carries any key that is not app-behaviour-only — an egress
  # allowlist or MCP policy is enough. So *any* MDM management of Claude, not just
  # an update policy, silently re-enables updates here, and nothing is logged when
  # it does (the "disabled by enterprise policy" line only appears when the policy
  # is applied, never when it is dropped).
  if [[ -f "$A_MANAGED_PLIST" || -f "$A_MANAGED_PLIST_USER" ]]; then
    warn "   ⚠️ This machine has an MDM-managed Claude configuration."
    warn "      Managed policy replaces the local tier wholesale, so the file just written"
    warn "      may be ignored and ${name} would auto-update again — silently."
    warn "      Verify after launching: grep '\\[updater\\]' ~/Library/Logs/${name}/main.log"
  fi
}

a_notes() {
  local name="$1"
  print ""
  print "  Auto-updates are off via the clone's own policy file; rebuild with"
  print "  ./clone-agent.sh ${name} after the original updates."
  print "  Note: the desktop app's built-in Claude Code reads ~/.claude, shared with"
  print "  the original app and the stock claude CLI. This profile's *generated* CLI"
  print "  launcher is the exception — it gets its own \$CLAUDE_CONFIG_DIR."
}

a_cli_notes() {
  local name="$1"
  print "  The launcher clears ANTHROPIC_* and CLAUDE_* before selecting this profile,"
  print "  so subscription login is deterministic. Run /login on first use."
  print "  This is a different config root from the desktop clone's built-in Claude"
  print "  Code, which deliberately keeps sharing ~/.claude — see the note at the top"
  print "  of adapters/claude.sh."
  print "  Per-profile settings belong in \$CLAUDE_CONFIG_DIR/settings.json (it has an"
  print "  'env' block) — ambient variables no longer reach the CLI, and MCP servers"
  print "  spawned by it inherit the cleared environment too, so give any that need an"
  print "  API key a per-server 'env' entry in that profile's MCP config."
}
