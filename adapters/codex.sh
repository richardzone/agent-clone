#!/bin/zsh
# Adapter: Codex desktop (OpenAI)
#
# Note the mismatched names: what gets installed is /Applications/ChatGPT.app,
# but the bundle id is com.openai.codex and the asar's productName is Codex.
#
# Loaded by clone-agent.sh. Interface contract: adapters/README.md.

A_LABEL="Codex"
A_SOURCE_DEFAULT="/Applications/ChatGPT.app"
A_EXEC_NAME="ChatGPT"                        # original executable under Contents/MacOS/
A_BUNDLE_ID_BASE="com.openai.codex"
A_FRAMEWORK="Codex Framework"
A_CLI_COMMAND="codex"

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
A_CLI_HOME_TEMPLATE="$A_CODEX_HOME_TEMPLATE"

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
  if ! strings -a "$src/Contents/Resources/app.asar" 2>/dev/null | grep -q 'CODEX_HOME'; then
    print "CODEX_HOME not found in app.asar — data isolation may no longer work"; return 1
  fi
  print "   CODEX_HOME support ✓"
  # Browser Use authenticates node_repl plus its parent and grandparent. The clone's
  # Electron executable is necessarily ad-hoc signed, so the adapter routes app-server
  # startup through the bundled OpenAI-signed Node executable. This override is the
  # supported entry point for doing that without modifying the asar again.
  if ! strings -a "$src/Contents/Resources/app.asar" 2>/dev/null | grep -q 'CODEX_CLI_PATH'; then
    print "CODEX_CLI_PATH not found in app.asar — Browser Use isolation may no longer work"; return 1
  fi
  local codex_bin="$src/Contents/Resources/codex"
  local node_bin="$src/Contents/Resources/cua_node/bin/node"
  # Structural: without these two the launcher chain cannot be built at all.
  [[ -x "$codex_bin" ]] || { print "Missing bundled codex executable"; return 1 }
  [[ -x "$node_bin" ]] || { print "Missing bundled Node executable"; return 1 }
  # Identity: only Browser Use depends on these, and the identifiers and Team ID
  # below are pinned to what OpenAI ships today. If they rotate either, the clone
  # itself is still fine and the chain may well still be accepted under the new
  # identity — so warn rather than block the whole build on a stale constant.
  local sig_ok=1
  codesign --verify --strict \
    -R='identifier "codex" and anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2"' \
    "$codex_bin" 2>/dev/null || sig_ok=0
  codesign --verify --strict \
    -R='identifier "node" and anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2"' \
    "$node_bin" 2>/dev/null || sig_ok=0
  if (( sig_ok )); then
    print "   Browser Use signed launch chain ✓"
  else
    print "   ⚠️  Bundled codex/Node no longer carry the expected OpenAI signature."
    print "      The clone will still build; Browser Use may stop working (AGENTS.md §10)."
  fi
}

# Codex's helper paths anchor to the framework name, so CFBundleName does not
# affect them and no renaming is required.
a_rename_helpers() { print "   (Codex helpers anchor to the framework name; no renaming needed)"; }

a_extra_plist() {
  local plist="$1"
  # Codex auto-updates via Sparkle. These two keys are absent from the original
  # Info.plist (the feed is configured in code), so add them as false to disable
  # automatic checks and installs — otherwise Sparkle would overwrite the clone
  # with the official package and wipe every customisation.
  /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$plist" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$plist"
  /usr/libexec/PlistBuddy -c "Add :SUAutomaticallyUpdate bool false" "$plist" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Set :SUAutomaticallyUpdate false" "$plist"
  print "   Sparkle auto-update disabled"
}

a_wrapper_env() {
  local name="$1"
  # Second isolation layer: login state, sessions and MCP config all live under CODEX_HOME
  print "export CODEX_HOME=\"${A_CODEX_HOME_TEMPLATE//<NAME>/$name}\""
  # Route app-server startup through a signed Node parent. The launcher ultimately
  # runs the untouched bundled codex binary with the exact arguments it received.
  print 'export CODEX_CLI_PATH="$APP_DIR/../Resources/codex-cli-launcher"'
}

a_cli_wrapper_env() {
  local name="$1"
  print "export CODEX_HOME=\"${A_CLI_HOME_TEMPLATE//<NAME>/$name}\""
}

# Keep both account auth and MCP OAuth credentials in the profile-specific
# CODEX_HOME instead of allowing a shared macOS Keychain entry.
a_cli_exec() {
  print 'exec codex -c '\''cli_auth_credentials_store="file"'\'' -c '\''mcp_oauth_credentials_store="file"'\'' "$@"'
}

a_sign_extra() {
  local app="$1"
  local fwdir="$(_a_fwdir "$app")"
  local h f
  cp "$REPO_DIR/tools/codex-cli-launcher" "$app/Contents/Resources/codex-cli-launcher"
  cp "$REPO_DIR/tools/codex-cli-launcher.cjs" "$app/Contents/Resources/codex-cli-launcher.cjs"
  chmod +x "$app/Contents/Resources/codex-cli-launcher"
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
  # Preserve the original Developer ID signature on Resources/codex. Browser Use
  # rejects the local pipe unless node_repl and both ancestors retain trusted
  # OpenAI identities; replacing this signature with ad-hoc breaks that chain.
  #
  # This assertion must stay explicit. a_sign_extra is called directly (not on the
  # left of ||), so set -e is live inside it: a bare failing command here would
  # abort the whole run with no message at all — and by this point step 2 has
  # already deleted the previously working clone.
  codesign --verify --strict "$app/Contents/Resources/codex" >/dev/null 2>&1 ||
    die "Resources/codex lost its Developer ID signature during the copy — Browser Use would not authorize"
  for f in "$app/Contents/Resources/native/"*; do
    [[ -f "$f" ]] && codesign --force --sign - "$f" >/dev/null 2>&1
  done
}

a_notes() {
  local name="$1"
  print ""
  print "  Note: Codex's keychain service names (Codex Safe Storage / Storage Key /"
  print "  MCP Credentials) are compiled into native code and unaffected by productName,"
  print "  so the clone shares those entries with the original."
  print "  Login state lives in \$CODEX_HOME/auth.json (a file, not the keychain), so logins"
  print "  are fully isolated — measured with no keychain prompts. The one exception:"
  print "  OAuth tokens for identically-named MCP servers overwrite each other."
}


a_cli_notes() {
  print "  Codex CLI auth and MCP OAuth credentials are forced to file storage under"
  print "  the profile-specific \$CODEX_HOME. Run 'codex login' through this launcher."
}
