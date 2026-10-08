#!/bin/zsh -f
# test-codex-layout.sh — regression checks for how the Codex adapter and the
# Browser Use launcher choose the bundled codex binary.
#
#   zsh -f tools/test-codex-layout.sh
#
# The adapter's _a_codex_signed decides which binary preflight and the post-copy
# assertion verify; tools/codex-cli-launcher.cjs decides which one the clone
# actually spawns. They must always agree, or a build verifies one binary and
# runs another (AGENTS.md section 13). Every case below builds a throwaway
# Resources/ tree in a fresh temp dir with stub executables, asks both sides,
# and compares. No real app is read or written. Needs `node` on PATH.
set -u
umask 022   # fixtures need traversable dirs and the exact modes set below
REPO="${0:A:h:h}"
T="$(mktemp -d)"; T="${T:A}"   # /var -> /private/var: node reports real paths
trap 'rm -rf "$T"' EXIT
fail=0; n=0

source "$REPO/adapters/codex.sh"

check() {  # $1 description, $2 condition result (0 = pass), $3 detail
  (( n++ ))
  if [[ "$2" == 0 ]]; then print "  ok   $1"; else print "  FAIL $1${3:+ — $3}"; fail=1; fi
}

stub() {  # $1 path: an executable that reports itself and its PATH tail
  mkdir -p "${1:h}"
  print -r -- '#!/bin/sh
echo "ran $0"
echo "pathtail ${PATH##*:}"
echo "pathdup $(printf %s "$PATH" | tr : "\n" | grep -cxF "$(dirname "$0")")"
echo "clipath ${CODEX_CLI_PATH-unset}"
echo "args $*"
exit 7' > "$1"
  chmod 755 "$1"   # explicit mode: +x would honour an unusual umask
}

# Build an app for one case. $1 name, then layout words:
#   new        nested CodexCLI.app executable
#   new-noexec nested file without the execute bit
#   new-dir    nested path is a directory
#   new-dangle nested path is a dangling symlink
#   new-link   nested path is a symlink to an executable file
#   bare       old-layout Resources/codex executable
#   bare-noexec old-layout file without the execute bit
#   bare-dir   old-layout path is a directory
mkapp() {
  local app="$T/$1.app" w; shift
  local res="$app/Contents/Resources" nested="$app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
  mkdir -p "$res"
  cp "$REPO/tools/codex-cli-launcher.cjs" "$res/"
  for w in "$@"; do
    case $w in
      new)        stub "$nested" ;;
      new-noexec) stub "$nested"; chmod -x "$nested" ;;
      new-dir)    mkdir -p "$nested" ;;
      new-dangle) mkdir -p "${nested:h}"; ln -s "$T/nowhere" "$nested" ;;
      new-link)   stub "$T/$app:t-target"; mkdir -p "${nested:h}"; ln -s "$T/$app:t-target" "$nested" ;;
      bare)       stub "$res/codex" ;;
      bare-noexec) stub "$res/codex"; chmod 644 "$res/codex" ;;
      bare-dir)   mkdir -p "$res/codex" ;;
    esac
  done
  print "$app"
}

# What preflight would verify, as the executable path ("" when nothing qualifies).
adapter_exe() {
  local s="$(_a_codex_signed "$1")"
  case "$s" in
    "")             print "" ;;
    *CodexCLI.app)  print "$s/Contents/MacOS/codex" ;;
    *)              print "$s" ;;
  esac
}

# What the launcher spawns: the "ran …" line, or "" when the spawn failed.
launcher_run() {  # $1 app, $2 PATH to hand it
  PATH="$2" "$NODE" "$1/Contents/Resources/codex-cli-launcher.cjs" --version 2>&1
}

expect_choice() {  # $1 description, $2 app, $3 expected: new | bare | none
  local app="$2" want exe out ran
  case $3 in
    new)  want="$app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" ;;
    bare) want="$app/Contents/Resources/codex" ;;
    none) want="" ;;
  esac
  exe="$(adapter_exe "$app")"
  out="$(launcher_run "$app" "/usr/bin:/bin")"
  ran="$(print -r -- "$out" | sed -n 's/^ran //p')"
  check "$1: adapter picks $3" "$([[ "$exe" == "$want" ]]; print $?)" "got '${exe#$T/}'"
  if [[ $3 == none ]]; then
    check "$1: launcher runs nothing" "$([[ -z "$ran" ]]; print $?)" "ran '${ran#$T/}'"
    check "$1: launcher reports the failed spawn" \
      "$([[ "$out" == *"Failed to launch the bundled codex binary"* ]]; print $?)" "$out"
  else
    check "$1: launcher runs the same binary" "$([[ "${ran:A}" == "${want:A}" ]]; print $?)" "ran '${ran#$T/}'"
  fi
}

# Call node by its real path: a version-manager shim may not run under the
# minimal PATH these cases hand the launcher.
NODE="$(node -p process.execPath 2>/dev/null)" || NODE=""
[[ -x "$NODE" ]] || { print "node is required"; exit 1 }

print "layout selection (adapter vs launcher)"
expect_choice "new layout only"              "$(mkapp a new)"              new
expect_choice "old layout only"              "$(mkapp b bare)"             bare
expect_choice "both layouts"                 "$(mkapp c new bare)"         new
expect_choice "nested not executable"        "$(mkapp d new-noexec bare)"  bare
expect_choice "nested is a directory"        "$(mkapp e new-dir bare)"     bare
expect_choice "nested dir, nothing else"     "$(mkapp f new-dir)"          none
expect_choice "nested dangling symlink"      "$(mkapp g new-dangle bare)"  bare
expect_choice "nested symlink to a binary"   "$(mkapp h new-link)"         new
expect_choice "bare path is a directory"     "$(mkapp i bare-dir)"         none
expect_choice "bare not executable"          "$(mkapp k bare-noexec)"      none
expect_choice "nested ok, bare not exec"     "$(mkapp l new bare-noexec)"  new
expect_choice "neither layout"               "$(mkapp j)"                  none

print "\nPATH handling (append, only if absent)"
app="$(mkapp p new)"
macos="$app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS"
out="$(launcher_run "$app" "/usr/bin:/bin")"
check "codex dir is appended last" "$([[ "$out" == *"pathtail $macos"* ]]; print $?)" "$out"
out="$(launcher_run "$app" "/usr/bin:$macos:/bin")"
check "an existing entry is not duplicated" "$([[ "$out" == *"pathdup 1"* ]]; print $?)" "$out"
check "…and not moved to the end" "$([[ "$out" != *"pathtail $macos"* ]]; print $?)" "$out"
app="$(mkapp q bare)"
out="$(launcher_run "$app" "/usr/bin:/bin:$app/Contents/Resources")"
check "old layout: Resources/ already present stays single" "$([[ "$out" == *"pathdup 1"* ]]; print $?)" "$out"

print "\nlauncher hygiene"
app="$(mkapp s new)"
out="$(CODEX_CLI_PATH=/somewhere PATH="/usr/bin:/bin" \
  "$NODE" "$app/Contents/Resources/codex-cli-launcher.cjs" app-server --x 2>/dev/null)"; rc=$?
check "CODEX_CLI_PATH is removed for the child" "$([[ "$out" == *"clipath unset"* ]]; print $?)" "$out"
check "arguments are forwarded verbatim" "$([[ "$out" == *"args app-server --x"* ]]; print $?)" "$out"
check "the child's exit code is propagated" "$([[ $rc == 7 ]]; print $?)" "rc=$rc"
app="$(mkapp r)"
PATH="/usr/bin:/bin" "$NODE" "$app/Contents/Resources/codex-cli-launcher.cjs" >/dev/null 2>&1; rc=$?
check "a failed spawn exits non-zero" "$([[ $rc != 0 ]]; print $?)" "rc=$rc"

print "\npreflight's missing-codex message"
# a_preflight on a minimal stub bundle: just enough framework and asar for it to
# reach the codex check, which needs no codesign when nothing qualifies.
pre_app() {  # $1 name, then layout words as for mkapp
  local app="$(mkapp "$@")" fw
  fw="$app/Contents/Frameworks/Codex Framework.framework"
  mkdir -p "$fw/Versions/A/Helpers"; ln -s A "$fw/Versions/Current"
  print 'CODEX_HOME CODEX_SPARKLE_ENABLED CODEX_CLI_PATH' > "$app/Contents/Resources/app.asar"
  stub "$app/Contents/Resources/cua_node/bin/node"
  print "$app"
}
pre_out() { a_preflight "$1" 2>&1; print "rc=$?" }
out="$(pre_out "$(pre_app m1 new-noexec)")"
check "non-executable nested codex: refused" "$([[ "$out" == *"Missing bundled codex executable"*"rc=1" ]]; print $?)" "$out"
check "…names both paths it looked for" "$([[ "$out" == *"CodexCLI.app/Contents/MacOS/codex, or Resources/codex before 26.928"* ]]; print $?)" "$out"
check "…and says the nested file is a broken install" \
  "$([[ "$out" == *"CodexCLI.app/Contents/MacOS/codex is present but not an executable regular file"* ]]; print $?)" "$out"
out="$(pre_out "$(pre_app m2 new-dir bare-dir)")"
check "directories at both paths: both reported as broken" \
  "$([[ "$out" == *"MacOS/codex is present but not"* && "$out" == *"Resources/codex is present but not"* ]]; print $?)" "$out"
out="$(pre_out "$(pre_app m3)")"
check "nothing at either path: no broken-install line" \
  "$([[ "$out" == *"Missing bundled codex executable"* && "$out" != *"present but not"* ]]; print $?)" "$out"

print ""
(( fail )) && { print "FAILED ($n checks)"; exit 1 }
print "all $n checks passed"
