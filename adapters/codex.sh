#!/bin/zsh
# Adapter: Codex desktop (OpenAI)
#
# Note the mismatched names: what gets installed is /Applications/ChatGPT.app,
# but the bundle id is com.openai.codex and the asar's productName is Codex.
#
# Loaded by clone-app.sh. Interface contract: adapters/README.md.

A_LABEL="Codex"
A_SOURCE_DEFAULT="/Applications/ChatGPT.app"
A_EXEC_NAME="ChatGPT"                        # original executable under Contents/MacOS/
A_BUNDLE_ID_BASE="com.openai.codex"
A_FRAMEWORK="Codex Framework"

# ⚠️ Codex's keychain service names (Codex Safe Storage / Codex Storage Key /
# Codex MCP Credentials) are not driven by the asar's productName — the first two
# come from a compile-time product-name constant inside Codex Framework, and the
# third is hard-coded in the Rust binary at Contents/Resources/codex
# (rmcp-client/src/oauth.rs). Clones therefore cannot get their own keychain
# entries and share them with the original. See README.md.
A_KEYCHAIN_ISOLATED=0

# Codex keeps login state, sessions, config.toml and MCP config under CODEX_HOME
# (default ~/.codex), shared with the codex CLI; --user-data-dir only isolates the
# Chromium layer.
# Confirmed present in the asar: resolveCodexHome() reads process.env.CODEX_HOME ?? ~/.codex
A_CODEX_HOME_TEMPLATE='$HOME/.codex-<NAME>'

# The framework's version directory is named after the Chromium version (e.g.
# 151.0.7922.76), not Claude's "A", so it can only be resolved through the
# Versions/Current symlink.
_a_fwdir() {
  local app="$1"
  local fw="$app/Contents/Frameworks/${A_FRAMEWORK}.framework"
  print "$fw/Versions/$(readlink "$fw/Versions/Current")"
}

a_preflight() {
  local src="$1"
  local fw="$src/Contents/Frameworks/${A_FRAMEWORK}.framework"
  [[ -d "$fw" ]] || { print "Missing ${A_FRAMEWORK}.framework"; return 1 }
  [[ -L "$fw/Versions/Current" ]] ||
    { print "${A_FRAMEWORK}.framework/Versions/Current is not a symlink — the version layout may have changed"; return 1 }
  local fwdir="$fw/Versions/$(readlink "$fw/Versions/Current")"
  [[ -d "$fwdir/Helpers" ]] || { print "Missing Helpers/ inside the framework"; return 1 }
  print "   Framework version directory ✓ ($(readlink "$fw/Versions/Current"))"
  # Helpers live inside the framework and their paths anchor to the framework name,
  # independent of CFBundleName — no renaming needed.
  print "   Helpers inside the framework ✓ ($(ls "$fwdir/Helpers" | grep -c '\.app$') .app bundles)"
  # CODEX_HOME support is what makes data isolation possible; without it the clone
  # would share ~/.codex with the original.
  # grep -qa reads the asar directly instead of piping through `strings`: one less
  # dependency (a missing `strings` would otherwise be reported as an upstream
  # change that never happened) and much faster, since grep stops at the first match.
  local asar="$src/Contents/Resources/app.asar"
  if ! grep -qa 'CODEX_HOME' "$asar"; then
    print "CODEX_HOME not found in app.asar — data isolation may no longer work"; return 1
  fi
  print "   CODEX_HOME support ✓"
  # The clone's only working auto-update switch. If upstream drops it the clone
  # would silently start checking again, so fail loudly here instead.
  if ! grep -qa 'CODEX_SPARKLE_ENABLED' "$asar"; then
    print "CODEX_SPARKLE_ENABLED not found in app.asar — the auto-update switch is gone"; return 1
  fi
  print "   CODEX_SPARKLE_ENABLED support ✓"
}

# Codex's helper paths anchor to the framework name, so CFBundleName does not
# affect them and no renaming is required.
a_rename_helpers() { print "   (Codex helpers anchor to the framework name; no renaming needed)"; }

# Auto-update is disabled through the wrapper (CODEX_SPARKLE_ENABLED), not here.
# Earlier versions wrote SUEnableAutomaticChecks/SUAutomaticallyUpdate into this
# plist; that was measured to have no effect and has been removed — see AGENTS.md
# "Sparkle reads NSUserDefaults before Info.plist".
a_extra_plist() { :; }

a_wrapper_env() {
  local name="$1"
  # Second isolation layer: login state, sessions and MCP config all live under CODEX_HOME
  print "export CODEX_HOME=\"${A_CODEX_HOME_TEMPLATE//<NAME>/$name}\""
  # Kill the updater at the root. Codex gates Sparkle on this variable itself:
  #   shouldIncludeSparkle(flavor, platform, env) =
  #       env.CODEX_SPARKLE_ENABLED !== 'false' && <flavor is shipping> && platform === 'darwin'
  # and the result feeds sparkleManager's enableUpdater, whose initializeUpdater()
  # returns early when false — so no feed is fetched, no update is staged, and the
  # header's update button never appears.
  # This has to be an environment variable: the Info.plist route does not work
  # (see AGENTS.md), and `defaults write` gets overwritten by Codex's own
  # sparkle.node, which calls setAutomaticallyChecksForUpdates: on launch.
  print "export CODEX_SPARKLE_ENABLED=false"
}

a_sign_extra() {
  local app="$1"
  local fwdir="$(_a_fwdir "$app")"
  local h f
  # Inside the framework: helper apps -> loose executables -> Libraries
  for h in "$fwdir/Helpers/"*.app; do
    [[ -d "$h" ]] && codesign --force --sign - "$h" >/dev/null 2>&1
  done
  for f in "$fwdir/Helpers/"*; do
    [[ -f "$f" ]] && codesign --force --sign - "$f" >/dev/null 2>&1
  done
  for f in "$fwdir/Libraries/"*; do
    [[ -f "$f" ]] && codesign --force --sign - "$f" >/dev/null 2>&1
  done
  codesign --force --sign - "$app/Contents/Frameworks/${A_FRAMEWORK}.framework" >/dev/null 2>&1
  # Sparkle also lives under Frameworks/ and is covered by the engine's *.framework loop
  for f in "$app/Contents/PlugIns/"*; do
    [[ -e "$f" ]] && codesign --force --sign - "$f" >/dev/null 2>&1
  done
  # Codex-specific: the bundle also ships the codex CLI binary and a few native helpers
  [[ -f "$app/Contents/Resources/codex" ]] &&
    codesign --force --sign - "$app/Contents/Resources/codex" >/dev/null 2>&1
  for f in "$app/Contents/Resources/native/"*; do
    [[ -f "$f" ]] && codesign --force --sign - "$f" >/dev/null 2>&1
  done
}

# Nothing to set up in the data directory: CODEX_HOME already isolates everything
# that matters, and the updater is disabled via the wrapper environment.
a_post_install() { :; }

a_notes() {
  local name="$1"
  print ""
  print "  Launch this clone through its wrapper — open -a ${name}, the Dock, or"
  print "  Contents/MacOS/ChatGPT. Running Contents/MacOS/${name} directly skips the"
  print "  wrapper, and with it CODEX_SPARKLE_ENABLED, so Sparkle starts and can"
  print "  replace the clone with the official package."
  print "  Note: Codex's keychain service names (Codex Safe Storage / Storage Key /"
  print "  MCP Credentials) are compiled into native code and unaffected by productName,"
  print "  so the clone shares those entries with the original."
  print "  Login state lives in \$CODEX_HOME/auth.json (a file, not the keychain), so logins"
  print "  are fully isolated — measured with no keychain prompts. The one exception:"
  print "  OAuth tokens for identically-named MCP servers overwrite each other."
}
