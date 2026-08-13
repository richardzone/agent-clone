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
