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

# Claude's updater is in-house with no plist switch to flip; the README tells users
# to ignore update prompts instead.
a_extra_plist() { :; }

# Claude only needs the Electron-level isolation, so the wrapper gets no extra env.
a_wrapper_env() { :; }

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

a_notes() { :; }

a_cli_notes() {
  local name="$1"
  print "  The launcher clears ANTHROPIC_* and CLAUDE_* before selecting this profile,"
  print "  so subscription login is deterministic. Run /login on first use."
  print "  Per-profile settings belong in \$CLAUDE_CONFIG_DIR/settings.json (it has an"
  print "  'env' block) — ambient variables no longer reach the CLI, and MCP servers"
  print "  spawned by it inherit the cleared environment too, so give any that need an"
  print "  API key a per-server 'env' entry in that profile's MCP config."
}
