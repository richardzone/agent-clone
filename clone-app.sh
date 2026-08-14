#!/bin/zsh
#
# clone-app.sh — clone an AI agent desktop app into a fully isolated second instance.
#
# Usage: ./clone-app.sh --help (the help text lives in usage() below).
# Design rationale, per-app differences and the verification checklist: AGENTS.md.
#
# ⚠️ Clones do not auto-update and must not be allowed to — re-run this script
#    after each upstream release.
#
set -e
setopt NULL_GLOB

REPO_DIR="${0:A:h}"
# --all uses this to invoke itself recursively. Stored as an absolute path at top
# level rather than using $0 in place: zsh rebinds $0 to the function name inside
# a function, so that logic would silently break if it were ever moved into one.
SELF="${0:A}"
PROFILE_DIR="$REPO_DIR/profiles"
ADAPTER_DIR="$REPO_DIR/adapters"

step() { print -P "\n%F{cyan}==> $1%f" }
info() { print "   $1" }
warn() { print -P "%F{yellow}$1%f" }
die()  { print -P "%F{red}ERROR: $1%f" >&2; exit 1 }

# Guard for options that take a value. Without it, `--data-dir --dry-run` would
# swallow the flag as its value and run for real while the user believes they asked
# for a preview, and a trailing `--icon` would abort with a raw zsh
# "shift count must be <= $#" instead of a usable message.
need_val() {   # call as: need_val "$@" — inspects the flag ($1) and its value ($2)
  [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "$1 requires a value"
}

# Read one interactive line into a named variable. The `if` wrapper both treats
# Ctrl-D as an explicit cancel and keeps read's non-zero return from tripping set -e.
ask() {   # ask <variable-name> <prompt>
  local __var="$1"
  if ! read -r "${__var}?$2"; then print "\nCancelled."; exit 0; fi
}

# The help text is inlined via a quoted heredoc: its contents are immune to shell
# expansion, and it does not depend on reading the script's own file (so it keeps
# working if the script is renamed, moved, or run as `zsh < clone-app.sh`).
usage() {
  cat <<'EOF'
clone-app.sh — clone an AI agent desktop app into a fully isolated second instance.

Supported apps are whatever lives in adapters/ (currently claude, codex).

Usage:
  ./clone-app.sh --init                                        # interactive setup (start here)
  ./clone-app.sh <Name> --app claude --icon path/to/icon.png   # create a clone
  ./clone-app.sh <Name>                                        # rebuild from stored profile
  ./clone-app.sh --all                                         # rebuild every clone (use after upgrades)
  ./clone-app.sh --list                                        # list configured clones

Options:
  <Name>               clone name; also the .app filename, display name and process name
  --app <kind>         which app to clone: claude | codex (required on first run,
                       case-insensitive)
  --icon <path>        icon, .icns or .png (png is converted automatically)
  --dry-run            preview only: run every check, print the plan, change nothing.
                       Works with any invocation, including --all and --init
  --bundle-id <id>     override the bundle ID (default: derived from the clone name)
  --data-dir <path>    override the Electron data directory
  --source <path>      override the source app path
  --dest-dir <path>    override the install directory (default: /Applications)

Arguments from the first run are stored in profiles/<Name>.conf; later rebuilds
need no arguments.

⚠️ Clones do not auto-update and must not be allowed to — see README.md.
EOF
  exit "${1:-0}"
}

# ===========================================================================
# Argument parsing
# ===========================================================================
NAME="" APP_KIND="" ICON="" BUNDLE_ID="" DATA_DIR="" SRC="" DEST_DIR=""
DO_ALL=0 DO_INIT=0 DRY_RUN=0

while (( $# )); do
  case "$1" in
    --all)       DO_ALL=1; shift ;;
    --init)      DO_INIT=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --list)
      profiles=("$PROFILE_DIR"/*.conf)
      (( ${#profiles} )) || { print "No clones configured yet."; exit 0 }
      print "Configured clones:"
      for p in $profiles; do
        unset P_APP; source "$p"
        printf "  %-22s %s\n" "${${p:t}:r}" "${${P_APP:-claude}:l}"
      done
      exit 0 ;;
    --app)       need_val "$@"; APP_KIND="${2:l}"; shift 2 ;;   # :l lowercases, so --app Codex works
    --icon)      need_val "$@"; ICON="$2"; shift 2 ;;
    --bundle-id) need_val "$@"; BUNDLE_ID="$2"; shift 2 ;;
    --data-dir)  need_val "$@"; DATA_DIR="$2"; shift 2 ;;
    --source)    need_val "$@"; SRC="$2"; shift 2 ;;
    --dest-dir)  need_val "$@"; DEST_DIR="$2"; shift 2 ;;
    -h|--help)   usage 0 ;;
    -*)          die "Unknown option: $1 (see --help)" ;;
    *)
      [[ -z "$NAME" ]] || die "Only one clone name allowed (already have '$NAME', then saw '$1')"
      NAME="$1"; shift ;;
  esac
done

# ===========================================================================
# --init: interactive setup. It only gathers arguments; the actual cloning still
# goes through the normal path below (by invoking this script recursively), so
# there is never a second copy of the engine logic.
# ===========================================================================
if (( DO_INIT )); then
  (( DO_ALL )) && die "--init cannot be combined with --all"
  [[ -z "$NAME" ]] || die "--init is interactive; don't also pass a clone name (got '$NAME')"
  # --init collects only name/app/icon and hands off to the normal path; the other
  # options would not be passed along, so reject them rather than ignore them.
  [[ -z "$APP_KIND$ICON$BUNDLE_ID$DATA_DIR$SRC$DEST_DIR" ]] ||
    die "--init takes no other options (except --dry-run).\n   For precise control use: ./clone-app.sh <Name> --app <kind> --icon <path> [options...]"
  [[ -t 0 ]] ||
    die "--init needs an interactive terminal. In scripts use: ./clone-app.sh <Name> --app <kind> --icon <path>"

  # Collect each adapter's label and default source path. Sourcing them in turn
  # overwrites the same variables, so copy the values out immediately.
  i_kind=() i_label=() i_src=()
  for a in "$ADAPTER_DIR"/*.sh; do
    unset A_LABEL A_SOURCE_DEFAULT
    source "$a"
    i_kind+=("${${a:t}:r}"); i_label+=("$A_LABEL"); i_src+=("$A_SOURCE_DEFAULT")
  done

  print -P "%F{cyan}Apps available to clone on this machine:%f"
  can_kind=() can_label=()
  for n in {1..${#i_kind}}; do
    if [[ -d "${i_src[$n]}" ]]; then
      printf "  %-8s %s\n" "${i_kind[$n]}" "${i_src[$n]}"
      can_kind+=("${i_kind[$n]}"); can_label+=("${i_label[$n]}")
    else
      printf "  %-8s %s  (not installed, skipped)\n" "${i_kind[$n]}" "${i_src[$n]}"
    fi
  done
  (( ${#can_kind} )) || die "No cloneable app found — install the original first, or point --source at it"

  plan_name=() plan_kind=() plan_icon=()
  for n in {1..${#can_kind}}; do
    kind="${can_kind[$n]}" label="${can_label[$n]}"

    ask reply "
Clone ${label}? [Y/n] "
    [[ -z "$reply" || "${reply:l}" == y* ]] || continue

    while true; do
      ask reply "  Clone name [My${label}] "
      cand="${reply:-My${label}}"
      [[ "$cand" =~ '^[A-Za-z][A-Za-z0-9._-]*$' ]] && break
      warn "  Letters, digits, dot, underscore and hyphen only, starting with a letter."
    done
    [[ -f "$PROFILE_DIR/${cand}.conf" ]] &&
      warn "  Note: profiles/${cand}.conf already exists and would be overwritten."

    # Offer one of the repo's bundled sample icons as the default
    dicon=""
    for f in "$REPO_DIR/icons/"*${kind}*.icns "$REPO_DIR/icons/"*${kind}*.png; do
      [[ -f "$f" ]] && { dicon="${f#$REPO_DIR/}"; break }
    done
    while true; do
      if [[ -n "$dicon" ]]; then
        ask reply "  Icon .png or .icns [$dicon] "
        cicon="${reply:-$dicon}"
      else
        ask reply "  Icon .png or .icns: "
        cicon="$reply"
      fi
      probe="$cicon"; [[ "$probe" == /* ]] || probe="$REPO_DIR/$probe"
      [[ -f "$probe" ]] && break
      warn "  No such file: $probe"
    done

    plan_name+=("$cand"); plan_kind+=("$kind"); plan_icon+=("$cicon")
  done

  (( ${#plan_name} )) || { print "\nNothing selected, exiting."; exit 0 }

  # Show the full commands before doing anything — every run installs something
  # into /Applications, so this confirmation is not optional.
  suffix=""; (( DRY_RUN )) && suffix=" --dry-run"
  print -P "\n%F{cyan}About to run:%f"
  for n in {1..${#plan_name}}; do
    print "  ./clone-app.sh ${plan_name[$n]} --app ${plan_kind[$n]} --icon ${plan_icon[$n]}${suffix}"
  done
  (( DRY_RUN )) && warn "(--dry-run: preview only, nothing will actually change)"

  ask reply "
Proceed? [y/N] "
  [[ "${reply:l}" == y* ]] || { print "Cancelled."; exit 0 }

  pass=(); (( DRY_RUN )) && pass=(--dry-run)
  for n in {1..${#plan_name}}; do
    "$SELF" "${plan_name[$n]}" --app "${plan_kind[$n]}" --icon "${plan_icon[$n]}" $pass
  done
  exit 0
fi

if (( DO_ALL )); then
  profiles=("$PROFILE_DIR"/*.conf)
  (( ${#profiles} )) || die "No profiles in profiles/ — create a clone before using --all"
  pass=()
  (( DRY_RUN )) && pass=(--dry-run)
  print -P "%F{cyan}Rebuilding ${#profiles} clone(s)%f"
  for p in $profiles; do "$SELF" "${${p:t}:r}" $pass; done
  if (( DRY_RUN )); then
    print -P "\n%F{yellow}--dry-run: all of the above was a preview; nothing was changed.%f"
  else
    print -P "\n%F{green}All clones rebuilt.%f"
  fi
  exit 0
fi

[[ -n "$NAME" ]] || usage 1
[[ "$NAME" =~ '^[A-Za-z][A-Za-z0-9._-]*$' ]] ||
  die "Clone name accepts letters, digits, dot, underscore and hyphen, starting with a letter: '$NAME'"

# ===========================================================================
# Profile: stored values act as defaults; command-line arguments win
# ===========================================================================
PROFILE="$PROFILE_DIR/${NAME}.conf"
if [[ -f "$PROFILE" ]]; then
  source "$PROFILE"
  [[ -n "$APP_KIND"  ]] || APP_KIND="${${P_APP:-claude}:l}"
  [[ -n "$ICON"      ]] || ICON="$P_ICON"
  [[ -n "$BUNDLE_ID" ]] || BUNDLE_ID="$P_BUNDLE_ID"
  [[ -n "$DATA_DIR"  ]] || DATA_DIR="$P_DATA_DIR"
  [[ -n "$SRC"       ]] || SRC="$P_SOURCE"
  [[ -n "$DEST_DIR"  ]] || DEST_DIR="$P_DEST_DIR"
fi

kinds=("$ADAPTER_DIR"/*.sh)
[[ -n "$APP_KIND" ]] || die "First run needs --app (available: ${${kinds[@]:t:r}})"
# Restrict the character set: this gives a clear error, and also stops things like
# ../ from escaping adapters/ and being sourced.
[[ "$APP_KIND" =~ '^[a-z0-9_-]+$' ]] ||
  die "--app accepts letters, digits, underscore and hyphen only: '$APP_KIND' (available: ${${kinds[@]:t:r}})"
ADAPTER="$ADAPTER_DIR/${APP_KIND}.sh"
[[ -f "$ADAPTER" ]] || die "No adapter for '$APP_KIND' (available: ${${kinds[@]:t:r}})"
source "$ADAPTER"

# Step 8 renames the real binary to <NAME> and installs the wrapper at the original
# <A_EXEC_NAME>. If the two collide, `mv f f` is a silent no-op (it returns 0), and the
# wrapper then overwrites the genuine Electron binary — yielding an app that execs
# itself forever, with the original gone. Compare case-insensitively, as the filesystem does.
[[ "${NAME:l}" != "${A_EXEC_NAME:l}" ]] ||
  die "Clone name must differ from ${A_LABEL}'s own executable name ('$A_EXEC_NAME') — pick another name"

: ${SRC:="$A_SOURCE_DEFAULT"}
: ${DEST_DIR:="/Applications"}
: ${BUNDLE_ID:="${A_BUNDLE_ID_BASE}.${${(L)NAME}//[^a-z0-9]/}"}
# Note the literal $HOME: this string is written into the wrapper and expanded
# there at runtime.
: ${DATA_DIR:="\$HOME/Library/Application Support/${NAME}"}

APP="$DEST_DIR/${NAME}.app"

[[ -d "$SRC" ]] ||
  die "Source app not found: $SRC\n   ${A_LABEL} may not be installed, or lives elsewhere — install it and retry, or pass --source with the real path."
[[ "${APP:A}" != "${SRC:A}" ]] || die "Clone path equals the source app; that would overwrite the original"
[[ -n "$ICON" ]] || die "First run needs --icon (.icns or .png)"

# Step 2 rebuilds the clone with `rm -rf "$APP"`, so refuse to touch anything that
# isn't ours: a slip like `./clone-app.sh Slack --app claude` would otherwise delete
# the real /Applications/Slack.app. Either a stored profile or a bundle ID already
# matching the one we would assign means we built it.
if [[ -d "$APP" && ! -f "$PROFILE" ]]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$existing_id" == "$BUNDLE_ID" ]] ||
    die "$APP already exists and was not created by this script (bundle ID '${existing_id:-unknown}').\n   Rebuilding would delete it. Choose a different clone name, or remove that app yourself first."
fi

# Relative paths resolve against the repo root, which keeps profiles portable
[[ "$ICON" == /* ]] || ICON="$REPO_DIR/$ICON"
[[ -f "$ICON" ]] || die "Icon not found: $ICON"

if [[ "${ICON:l}" == *.png ]]; then
  icns_out="${ICON:r}.icns"
  if (( DRY_RUN )); then
    # Generating the icns is a write, so under dry-run just report it
    info "(dry-run) would convert ${ICON:t} to ${icns_out:t}"
  else
    step "Pre-step: png -> icns"
    zsh "$REPO_DIR/tools/make-icon.sh" "$ICON" "$icns_out"
  fi
  ICON="$icns_out"
elif [[ "${ICON:l}" != *.icns ]]; then
  die "Icon must be .icns or .png: $ICON"
fi

if (( DRY_RUN )); then
  print -P "\n%F{cyan}Clone target%f %F{yellow}(dry-run, preview only)%f"
else
  print -P "\n%F{cyan}Clone target%f"
fi
info "Name       : $NAME"
info "Type       : $APP_KIND ($A_LABEL)"
info "Install to : $APP"
info "Source     : $SRC ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Contents/Info.plist" 2>/dev/null))"
info "Bundle ID  : $BUNDLE_ID"
info "Data dir   : $DATA_DIR"
info "Icon       : ${ICON#$REPO_DIR/}"

# ===========================================================================
step "Preflight: verify structural assumptions about the source app"
# ===========================================================================
# Each adapter checks the structure it depends on (helper naming, framework
# layout, ...). Better to abort before touching anything than to silently produce
# an app that installs and doesn't work.
a_preflight "$SRC" || die "Preflight failed — see \"When preflight fails\" in AGENTS.md"

# Informational only: these files are copied along with the bundle untouched.
UNPACKED_DIR="$SRC/Contents/Resources/app.asar.unpacked"
UNPACKED_COUNT=0
[[ -d "$UNPACKED_DIR" ]] && UNPACKED_COUNT=$(find "$UNPACKED_DIR" -type f | wc -l | tr -d ' ')
info "Files outside the asar: ${UNPACKED_COUNT} (copied as-is, never repacked)"

# ===========================================================================
# The dry-run boundary: everything above is read-only; everything below touches
# the filesystem.
# ===========================================================================
if (( DRY_RUN )); then
  print -P "\n%F{yellow}--dry-run: stopping here, nothing was changed.%f"
  info "Without --dry-run it would go on to:"
  info "  1. Quit any running ${NAME}, then delete and rebuild ${APP}"
  info "  2. Rewrite the bundle identity (name / bundle ID / icon)"
  info "  3. Handle Electron helpers, patch the asar productName in place and sync the integrity hash"
  info "  4. Install the wrapper and re-sign ad-hoc, inside-out"
  info "  5. Run the adapter's data-directory setup under ${DATA_DIR}"
  info "  6. Write ${PROFILE#$REPO_DIR/}"
  exit 0
fi

# ===========================================================================
step "1/9 Quitting any running ${NAME}"
# ===========================================================================
pkill -f "$APP" 2>/dev/null || true
sleep 3

# ===========================================================================
step "2/9 Copying the bundle (large, takes a moment)"
# ===========================================================================
rm -rf "$APP"
cp -R "$SRC" "$APP"

# ===========================================================================
step "3/9 Rewriting the bundle identity"
# ===========================================================================
plist="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${NAME}" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${NAME}" "$plist"
# The bundle ID is the critical one: leave it alone and macOS treats both apps as
# the same application.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$plist"
# Recent Electron reads the icon from Assets.car via CFBundleIconName, so that key
# must be deleted for a custom icns to take effect.
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile ${NAME}.icns" "$plist"
a_extra_plist "$plist"

# ===========================================================================
step "4/9 Installing the icon"
# ===========================================================================
cp "$ICON" "$APP/Contents/Resources/${NAME}.icns"

# ===========================================================================
step "5/9 Handling Electron helpers"
# ===========================================================================
a_rename_helpers "$APP" "$NAME"

# ===========================================================================
step "6/9 Patching productName in app.asar (in place)"
# ===========================================================================
# For Claude this is what delivers keychain isolation: Chromium's Safe Storage
#   service name is "<app name> Safe Storage", and a packaged Electron app takes
#   that name from productName in the asar's package.json — not from Info.plist's
#   CFBundleName, which has been measured to have no effect.
# For Codex the service names are compiled into native code, so this does nothing
#   for the keychain (see adapters/codex.sh); it is still applied to keep process
#   identity and crash reports consistent, with no downside.
#
# In-place rewriting rather than unpack-and-repack: the asar's unpack rules (which
# files must stay outside the archive) cannot be reliably inferred from a finished
# bundle — Codex keeps an entire node_modules subtree outside, and reproducing it
# with globs misses hundreds of files, yielding an app that installs and doesn't
# work. An in-place rewrite touches this one field; every other unpacked file and
# every data offset is unaffected.
asar="$APP/Contents/Resources/app.asar"
new_hash="$(node "$REPO_DIR/tools/patch-asar-productname.js" "$asar" "$NAME")"
[[ -n "$new_hash" ]] || die "asar rewrite failed"

# ===========================================================================
step "7/9 Syncing the ASAR integrity hash"
# ===========================================================================
# Electron validates the SHA256 of the asar **header**, not the whole file.
# The previous step changed package.json's content checksum inside that header,
# so it has to be synced or launching fails with FATAL: Integrity check failed.
/usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash ${new_hash}" "$plist"
info "header hash = ${new_hash}"

# ===========================================================================
step "8/9 Installing the wrapper (so Finder/Dock launches stay isolated too)"
# ===========================================================================
# A double-click passes no command-line arguments, so --user-data-dir (plus any
# environment the adapter needs) is baked into a wrapper. CFBundleExecutable keeps
# pointing at the original name (now the wrapper), while the real binary is renamed
# to the clone name so the process name and menu bar show the clone.
exe="$APP/Contents/MacOS/${A_EXEC_NAME}"
real="$APP/Contents/MacOS/${NAME}"
[[ -f "$exe" ]] || die "Main executable not found at $exe (the adapter's A_EXEC_NAME may be wrong)"
mv "$exe" "$real"
{
  print '#!/bin/zsh'
  print 'APP_DIR="$(cd "$(dirname "$0")" && pwd)"'
  a_wrapper_env "$NAME"
  print "exec \"\$APP_DIR/${NAME}\" --user-data-dir=\"${DATA_DIR}\" \"\$@\""
} > "$exe"
chmod +x "$exe"

# ===========================================================================
step "9/9 Re-signing ad-hoc, inside-out"
# ===========================================================================
# Any change to the bundle invalidates its signature and the app won't launch.
# Order matters: sign the deepest code first and the outer bundle last, so the
# outer seal covers everything already signed.
# Never sign with codesign --deep (deprecated by Apple; it mismatches helper
# signatures and causes crashes).
a_sign_extra "$APP"
for fwk in "$APP/Contents/Frameworks/"*.framework; do
  codesign --force --sign - "$fwk" >/dev/null 2>&1
done
for h in "$APP/Contents/Frameworks/"*.app; do
  codesign --force --sign - "$h" >/dev/null 2>&1
done
find "$APP/Contents/Resources/app.asar.unpacked" -type f \
     \( -perm +111 -o -name '*.node' -o -name '*.dylib' \) -print0 2>/dev/null |
  while IFS= read -r -d '' f; do codesign --force --sign - "$f" >/dev/null 2>&1; done
codesign --force --sign - "$real" >/dev/null 2>&1
codesign --force --sign - "$APP"  >/dev/null 2>&1

codesign --verify --deep --strict "$APP" || die "Signature verification failed"
info "Signature OK"

# ===========================================================================
step "Post-install: adapter setup inside the data directory"
# ===========================================================================
# Everything above writes inside the .app; this writes next to it, in the clone's
# own data directory. That directory survives rebuilds by design (which is what
# keeps logins and history), so this has to be idempotent — Claude uses it to drop
# in the policy file that disables auto-updates.
# DATA_DIR holds a literal $HOME so it can be written into the wrapper verbatim;
# expand it here, where a real path is needed. A --data-dir given as an absolute
# path contains no $HOME and is passed through untouched.
a_post_install "$NAME" "${DATA_DIR/\$HOME/$HOME}"

# ===========================================================================
step "Refreshing Launch Services / icon cache"
# ===========================================================================
"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" -f "$APP"
killall Dock 2>/dev/null || true

# ===========================================================================
# Save the profile so later rebuilds are just ./clone-app.sh <Name>
# ===========================================================================
mkdir -p "$PROFILE_DIR"
icon_store="$ICON"
[[ "$icon_store" == "$REPO_DIR/"* ]] && icon_store="${icon_store#$REPO_DIR/}"
# Values must be written single-quoted (${(qq)} handles quoting and escaping).
# With double quotes, the literal $HOME in DATA_DIR would expand at source time
# into an absolute path, pinning the profile to the current user.
{
  print "# Generated by clone-app.sh — the clone parameters for ${NAME},"
  print "# so an upstream release only needs ./clone-app.sh ${NAME} (or --all)."
  print "P_APP=${(qq)APP_KIND}"
  print "P_ICON=${(qq)icon_store}"
  print "P_BUNDLE_ID=${(qq)BUNDLE_ID}"
  print "P_DATA_DIR=${(qq)DATA_DIR}"
  print "P_SOURCE=${(qq)SRC}"
  print "P_DEST_DIR=${(qq)DEST_DIR}"
} > "$PROFILE"

print -P "\n%F{green}Done.%f"
info "App      : $APP"
info "Version  : $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)"
info "Data dir : $DATA_DIR"
info "Profile  : ${PROFILE#$REPO_DIR/}"
a_notes "$NAME"
print "\nLaunch:   open \"$APP\""
print "Rebuild:  ./clone-app.sh ${NAME}       (after an upstream release)"
