#!/bin/zsh
# Adapter: Claude desktop (Anthropic)
#
# Loaded by clone-app.sh. Interface contract: adapters/README.md.

A_LABEL="Claude"
A_SOURCE_DEFAULT="/Applications/Claude.app"
A_EXEC_NAME="Claude"                                  # original executable under Contents/MacOS/
A_BUNDLE_ID_BASE="com.anthropic.claudefordesktop"
A_FRAMEWORK=""                                        # main framework name; empty = nothing special

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
  # The policy key a_post_install writes. If upstream renames or drops it the clone
  # would silently resume hourly update downloads, so fail loudly here instead.
  if ! strings -a "$src/Contents/Resources/app.asar" 2>/dev/null | grep -q 'disableAutoUpdates'; then
    print "disableAutoUpdates not found in app.asar — the auto-update policy key is gone"; return 1
  fi
  print "   disableAutoUpdates policy key ✓"
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

# Claude only needs the Electron-level isolation, so the wrapper gets no extra env.
# Deliberately NOT setting CLAUDE_CONFIG_DIR — see the note at the top of this file.
a_wrapper_env() { :; }

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
    "${data_dir}${A_POLICY_ROOT_SUFFIX}/configLibrary" '{"disableAutoUpdates":true}'
}

a_notes() {
  local name="$1"
  print ""
  print "  Auto-updates are off via the clone's own policy file; rebuild with"
  print "  ./clone-app.sh ${name} after the original updates."
  print "  Note: Claude Code's config (~/.claude — settings, sessions, history,"
  print "  plugins) is shared with the original app and the claude CLI."
}
