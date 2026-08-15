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
# Namespaces the generated launcher clears before setting anything. OPENAI_* covers
# OPENAI_API_KEY, which is the default provider's env_key and would otherwise bill
# this profile's session to an API-key account instead of its ChatGPT login.
A_CLI_ENV_NAMESPACES=('OPENAI_*' 'CODEX_*')

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
  # Browser Use authenticates node_repl plus its parent and grandparent. The clone's
  # Electron executable is necessarily ad-hoc signed, so the adapter routes app-server
  # startup through the bundled OpenAI-signed Node executable. This override is the
  # supported entry point for doing that without modifying the asar again.
  if ! grep -qa 'CODEX_CLI_PATH' "$asar"; then
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
    print "      The clone will still build; Browser Use may stop working (AGENTS.md §13)."
  fi
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
  # Route app-server startup through a signed Node parent. The launcher ultimately
  # runs the untouched bundled codex binary with the exact arguments it received.
  print 'export CODEX_CLI_PATH="$APP_DIR/../Resources/codex-cli-launcher"'
}

# codex silently ignores an unknown -c key but rejects an invalid *value* for a
# known one, naming the key in the error. So a deliberately-bogus value is a
# canary: if a key is ever renamed upstream, the two overrides below would stop
# applying with no symptom at all, and MCP OAuth credentials would quietly revert
# to the shared Keychain entry that README.md documents as un-isolatable.
#
# This warns rather than aborting, for the same reason the signature assertions in
# a_preflight do: it is pinned to today's error phrasing, and a clone that still
# builds is better than one blocked by a constant that drifted. It also has to
# tell "codex ran and did not name the key" apart from "codex did not run at all",
# or every unrelated codex failure gets reported as an upstream rename.
a_cli_preflight() {
  local key out rc tmp
  tmp="$(mktemp -d)" || { print "   ⚠️  Could not create a temp dir; skipped the credential-store check."; return 0 }
  for key in cli_auth_credentials_store mcp_oauth_credentials_store; do
    out="$(CODEX_HOME="$tmp" codex -c "${key}=\"__canary__\"" login status 2>&1)"; rc=$?
    if (( rc == 0 )); then
      print "   ⚠️  codex accepted a bogus value for '${key}'. That key may have been renamed"
      print "      upstream, in which case credentials silently fall back to the shared Keychain."
    elif [[ "$out" != *"$key"* ]]; then
      print "   ⚠️  Could not check '${key}': codex exited ${rc} without naming it."
      print "      This is usually an unrelated codex problem, not a renamed key."
    else
      continue
    fi
    rm -rf "$tmp"
    return 0
  done
  rm -rf "$tmp"
  print "   Credential-store overrides still recognised ✓"
}

a_cli_wrapper_env() {
  local name="$1"
  print "export CODEX_HOME=\"${A_CLI_HOME_TEMPLATE//<NAME>/$name}\""
}

# Keep both account auth and MCP OAuth credentials in the profile-specific
# CODEX_HOME instead of allowing a shared macOS Keychain entry.
# $agent_cli is resolved by the engine on the lines just above this one: the path
# pinned at preflight, or a PATH lookup if a runtime manager has since moved it.
a_cli_exec() {
  print 'exec "$agent_cli" -c '\''cli_auth_credentials_store="file"'\'' -c '\''mcp_oauth_credentials_store="file"'\'' "$@"'
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


a_cli_notes() {
  print "  Account auth and MCP OAuth credentials are forced to file storage under the"
  print "  profile-specific \$CODEX_HOME. Run 'codex login' through this launcher."
  print "  The launcher clears OPENAI_* and CODEX_* first, so an ambient OPENAI_API_KEY"
  print "  can no longer bill this profile to a different account. MCP servers spawned"
  print "  by the CLI inherit that cleared environment — give any that need a key a"
  print "  per-server 'env' entry under mcp_servers in \$CODEX_HOME/config.toml."
}
