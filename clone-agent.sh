#!/bin/zsh
#
# clone-agent.sh — create isolated desktop and CLI instances of AI agents.
#
# Usage: ./clone-agent.sh --help (the help text lives in usage() below).
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
# working if the script is renamed, moved, or run as `zsh < clone-agent.sh`).
usage() {
  cat <<'EOF'
clone-agent.sh — create isolated desktop and CLI instances of AI agents.

Supported agents are whatever lives in adapters/ (currently claude, codex).

Usage:
  ./clone-agent.sh --init                                      # interactive setup (start here)
  ./clone-agent.sh <Name> --app claude --icon path/to/icon.png # create app + CLI (default)
  ./clone-agent.sh <Name> --app codex --target cli             # create only a CLI launcher
  ./clone-agent.sh <Name>                                      # rebuild from stored profile
  ./clone-agent.sh --all                                       # rebuild every configured profile
  ./clone-agent.sh --list                                      # list configured profiles

Options:
  <Name>               clone name; also the .app filename, display name and process name
  --app <kind>         which app to clone: claude | codex (required on first run,
                       case-insensitive)
  --target <target>    what to manage: all | app | cli (default: all on new profiles;
                       legacy profiles without this field remain app-only)
  --icon <path>        desktop icon, .icns or .png (required for app/all targets;
                       png is converted automatically)
  --cli-name <name>    generated CLI command name (default: <kind>-<lowercase-name>)
  --cli-bin-dir <path> launcher directory (default: $HOME/.local/bin)
  --dry-run            preview only: run every check, print the plan, change nothing.
                       Works with any invocation, including --all and --init
  --bundle-id <id>     override the bundle ID (default: derived from the clone name)
  --data-dir <path>    override the Electron data directory
  --source <path>      override the source app path
  --dest-dir <path>    override the install directory (default: /Applications)

Arguments from the first run are stored together in profiles/<Name>.conf; later
rebuilds need no arguments. The desktop app and CLI share the same account state
where the vendor supports it (Codex uses one profile-specific CODEX_HOME).

⚠️ Clones do not auto-update and must not be allowed to — see README.md.
EOF
  exit "${1:-0}"
}

# ===========================================================================
# Argument parsing
# ===========================================================================
NAME="" APP_KIND="" TARGET="" ICON="" BUNDLE_ID="" DATA_DIR="" SRC="" DEST_DIR=""
CLI_NAME="" CLI_BIN_DIR=""
DO_ALL=0 DO_INIT=0 DRY_RUN=0 TARGET_SET=0

while (( $# )); do
  case "$1" in
    --all)       DO_ALL=1; shift ;;
    --init)      DO_INIT=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --list)
      profiles=("$PROFILE_DIR"/*.conf)
      (( ${#profiles} )) || { print "No profiles configured yet."; exit 0 }
      print "Configured profiles:"
      for p in $profiles; do
        unset P_APP P_TARGET; source "$p"
        printf "  %-22s %-9s %s\n" "${${p:t}:r}" "${${P_APP:-claude}:l}" "${${P_TARGET:-app}:l}"
      done
      exit 0 ;;
    --app)       need_val "$@"; APP_KIND="${2:l}"; shift 2 ;;   # :l lowercases, so --app Codex works
    --target)    need_val "$@"; TARGET="${2:l}"; TARGET_SET=1; shift 2 ;;
    --icon)      need_val "$@"; ICON="$2"; shift 2 ;;
    --cli-name)  need_val "$@"; CLI_NAME="$2"; shift 2 ;;
    --cli-bin-dir) need_val "$@"; CLI_BIN_DIR="$2"; shift 2 ;;
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
  # --init collects only name/app/target/icon and hands off to the normal path; the other
  # options would not be passed along, so reject them rather than ignore them.
  [[ -z "$APP_KIND$TARGET$ICON$BUNDLE_ID$DATA_DIR$SRC$DEST_DIR$CLI_NAME$CLI_BIN_DIR" ]] ||
    die "--init takes no other options (except --dry-run).\n   For precise control use: ./clone-agent.sh <Name> --app <kind> --target <target> [options...]"
  [[ -t 0 ]] ||
    die "--init needs an interactive terminal. In scripts use: ./clone-agent.sh <Name> --app <kind> --target <target> [options...]"

  # Collect each adapter's label and default source path. Sourcing them in turn
  # overwrites the same variables, so copy the values out immediately.
  i_kind=() i_label=() i_src=() i_cli=()
  for a in "$ADAPTER_DIR"/*.sh; do
    unset A_LABEL A_SOURCE_DEFAULT A_CLI_COMMAND
    source "$a"
    i_kind+=("${${a:t}:r}"); i_label+=("$A_LABEL"); i_src+=("$A_SOURCE_DEFAULT"); i_cli+=("$A_CLI_COMMAND")
  done

  print -P "%F{cyan}Agents available to isolate on this machine:%f"
  can_kind=() can_label=() can_app=() can_cli=()
  for n in {1..${#i_kind}}; do
    has_app=0 has_cli=0
    [[ -d "${i_src[$n]}" ]] && has_app=1
    command -v "${i_cli[$n]}" >/dev/null 2>&1 && has_cli=1
    printf "  %-8s app:%-3s  cli:%-3s\n" "${i_kind[$n]}" "$([[ $has_app == 1 ]] && print yes || print no)" "$([[ $has_cli == 1 ]] && print yes || print no)"
    if (( has_app || has_cli )); then
      can_kind+=("${i_kind[$n]}"); can_label+=("${i_label[$n]}")
      can_app+=("$has_app"); can_cli+=("$has_cli")
    fi
  done
  (( ${#can_kind} )) || die "No supported desktop app or CLI found"

  plan_name=() plan_kind=() plan_target=() plan_icon=()
  for n in {1..${#can_kind}}; do
    kind="${can_kind[$n]}" label="${can_label[$n]}" has_app="${can_app[$n]}" has_cli="${can_cli[$n]}"

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

    while true; do
      ask reply "  Target: all, app, or cli [all] "
      ctarget="${${reply:-all}:l}"
      if [[ "$ctarget" == all || "$ctarget" == app || "$ctarget" == cli ]]; then
        if [[ "$ctarget" != cli && "$has_app" != 1 ]]; then
          warn "  ${label} desktop app is not installed; choose cli."
        elif [[ "$ctarget" != app && "$has_cli" != 1 ]]; then
          warn "  ${label} CLI is not installed; choose app."
        else
          break
        fi
      else
        warn "  Choose all, app, or cli."
      fi
    done

    cicon=""
    if [[ "$ctarget" != cli ]]; then
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
    fi

    plan_name+=("$cand"); plan_kind+=("$kind"); plan_target+=("$ctarget"); plan_icon+=("$cicon")
  done

  (( ${#plan_name} )) || { print "\nNothing selected, exiting."; exit 0 }

  # Show the full commands before doing anything. App targets write under the
  # destination directory and CLI targets install a launcher, so confirmation is
  # never optional.
  suffix=""; (( DRY_RUN )) && suffix=" --dry-run"
  print -P "\n%F{cyan}About to run:%f"
  for n in {1..${#plan_name}}; do
    cmd="  ./clone-agent.sh ${plan_name[$n]} --app ${plan_kind[$n]} --target ${plan_target[$n]}"
    [[ -n "${plan_icon[$n]}" ]] && cmd+=" --icon ${plan_icon[$n]}"
    print "${cmd}${suffix}"
  done
  (( DRY_RUN )) && warn "(--dry-run: preview only, nothing will actually change)"

  ask reply "
Proceed? [y/N] "
  [[ "${reply:l}" == y* ]] || { print "Cancelled."; exit 0 }

  pass=(); (( DRY_RUN )) && pass=(--dry-run)
  for n in {1..${#plan_name}}; do
    args=("${plan_name[$n]}" --app "${plan_kind[$n]}" --target "${plan_target[$n]}")
    [[ -n "${plan_icon[$n]}" ]] && args+=(--icon "${plan_icon[$n]}")
    "$SELF" $args $pass
  done
  exit 0
fi

if (( DO_ALL )); then
  profiles=("$PROFILE_DIR"/*.conf)
  (( ${#profiles} )) || die "No profiles in profiles/ — create a clone before using --all"
  pass=()
  (( DRY_RUN )) && pass=(--dry-run)
  (( TARGET_SET )) && pass+=(--target "$TARGET")
  print -P "%F{cyan}Rebuilding ${#profiles} profile(s)%f"
  for p in $profiles; do "$SELF" "${${p:t}:r}" $pass; done
  if (( DRY_RUN )); then
    print -P "\n%F{yellow}--dry-run: all of the above was a preview; nothing was changed.%f"
  else
    print -P "\n%F{green}All profiles rebuilt.%f"
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
PROFILE_EXISTS=0
if [[ -f "$PROFILE" ]]; then
  PROFILE_EXISTS=1
  source "$PROFILE"
  [[ -n "$APP_KIND"  ]] || APP_KIND="${${P_APP:-claude}:l}"
  [[ -n "$TARGET"    ]] || TARGET="${${P_TARGET:-app}:l}"
  [[ -n "$ICON"      ]] || ICON="$P_ICON"
  [[ -n "$BUNDLE_ID" ]] || BUNDLE_ID="$P_BUNDLE_ID"
  [[ -n "$DATA_DIR"  ]] || DATA_DIR="$P_DATA_DIR"
  [[ -n "$SRC"       ]] || SRC="$P_SOURCE"
  [[ -n "$DEST_DIR"  ]] || DEST_DIR="$P_DEST_DIR"
  [[ -n "$CLI_NAME"  ]] || CLI_NAME="$P_CLI_NAME"
  [[ -n "$CLI_BIN_DIR" ]] || CLI_BIN_DIR="$P_CLI_BIN_DIR"
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

# Profiles created before CLI support intentionally remain app-only. New
# profiles default to all, including non-interactive creation.
if [[ -z "$TARGET" ]]; then
  (( PROFILE_EXISTS )) && TARGET="app" || TARGET="all"
fi
[[ "$TARGET" == all || "$TARGET" == app || "$TARGET" == cli ]] ||
  die "--target must be all, app, or cli (got '$TARGET')"
TARGET_APP=0 TARGET_CLI=0
[[ "$TARGET" == all || "$TARGET" == app ]] && TARGET_APP=1
[[ "$TARGET" == all || "$TARGET" == cli ]] && TARGET_CLI=1

: ${CLI_NAME:="${APP_KIND}-${NAME:l}"}
: ${CLI_BIN_DIR:='$HOME/.local/bin'}
[[ "$CLI_NAME" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]] ||
  die "--cli-name accepts letters, digits, dot, underscore and hyphen: '$CLI_NAME'"
[[ "${CLI_NAME:l}" != "${A_CLI_COMMAND:l}" ]] ||
  die "--cli-name must differ from the vendor command '$A_CLI_COMMAND' (it would recursively launch itself)"

expand_home_path() {
  local p="$1"
  if [[ "$p" == '$HOME' ]]; then
    print "$HOME"
  elif [[ "$p" == '$HOME/'* ]]; then
    print "$HOME/${p#\$HOME/}"
  else
    print "$p"
  fi
}
CLI_BIN_REAL="$(expand_home_path "$CLI_BIN_DIR")"
CLI_LAUNCHER="$CLI_BIN_REAL/$CLI_NAME"
CLI_HOME="${A_CLI_HOME_TEMPLATE//<NAME>/$NAME}"
CLI_HOME_REAL="$(expand_home_path "$CLI_HOME")"

# Step 8 renames the real binary to <NAME> and installs the wrapper at the original
# <A_EXEC_NAME>. If the two collide, `mv f f` is a silent no-op (it returns 0), and the
# wrapper then overwrites the genuine Electron binary — yielding an app that execs
# itself forever, with the original gone. Compare case-insensitively, as the filesystem does.
(( ! TARGET_APP )) || [[ "${NAME:l}" != "${A_EXEC_NAME:l}" ]] ||
  die "Clone name must differ from ${A_LABEL}'s own executable name ('$A_EXEC_NAME') — pick another name"

: ${SRC:="$A_SOURCE_DEFAULT"}
: ${DEST_DIR:="/Applications"}
: ${BUNDLE_ID:="${A_BUNDLE_ID_BASE}.${${(L)NAME}//[^a-z0-9]/}"}
# Note the literal $HOME: this string is written into the wrapper and expanded
# there at runtime.
: ${DATA_DIR:="\$HOME/Library/Application Support/${NAME}"}

APP="$DEST_DIR/${NAME}.app"

(( ! TARGET_APP )) || [[ -d "$SRC" ]] ||
  die "Source app not found: $SRC\n   ${A_LABEL} may not be installed, or lives elsewhere — install it and retry, or pass --source with the real path."
(( ! TARGET_APP )) || [[ "${APP:A}" != "${SRC:A}" ]] || die "Clone path equals the source app; that would overwrite the original"
(( ! TARGET_APP )) || [[ -n "$ICON" ]] || die "The app/all target needs --icon on first run (.icns or .png)"

# Step 2 rebuilds the clone with `rm -rf "$APP"`, so refuse to touch anything that
# isn't ours: a slip like `./clone-agent.sh Slack --app claude` would otherwise delete
# the real /Applications/Slack.app. Either a stored profile or a bundle ID already
# matching the one we would assign means we built it.
if (( TARGET_APP )) && [[ -d "$APP" && ! -f "$PROFILE" ]]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$existing_id" == "$BUNDLE_ID" ]] ||
    die "$APP already exists and was not created by this script (bundle ID '${existing_id:-unknown}').\n   Rebuilding would delete it. Choose a different clone name, or remove that app yourself first."
fi

# Relative paths resolve against the repo root, which keeps profiles portable
if (( TARGET_APP )); then
  [[ "$ICON" == /* ]] || ICON="$REPO_DIR/$ICON"
  [[ -f "$ICON" ]] || die "Icon not found: $ICON"
fi

if (( TARGET_APP )) && [[ "${ICON:l}" == *.png ]]; then
  icns_out="${ICON:r}.icns"
  if (( DRY_RUN )); then
    # Generating the icns is a write, so under dry-run just report it
    info "(dry-run) would convert ${ICON:t} to ${icns_out:t}"
  else
    step "Pre-step: png -> icns"
    zsh "$REPO_DIR/tools/make-icon.sh" "$ICON" "$icns_out"
  fi
  ICON="$icns_out"
elif (( TARGET_APP )) && [[ "${ICON:l}" != *.icns ]]; then
  die "Icon must be .icns or .png: $ICON"
fi

if (( DRY_RUN )); then
  print -P "\n%F{cyan}Clone target%f %F{yellow}(dry-run, preview only)%f"
else
  print -P "\n%F{cyan}Clone target%f"
fi
info "Name       : $NAME"
info "Type       : $APP_KIND ($A_LABEL)"
info "Target     : $TARGET"
if (( TARGET_APP )); then
  info "App        : $APP"
  info "Source     : $SRC ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Contents/Info.plist" 2>/dev/null))"
  info "Bundle ID  : $BUNDLE_ID"
  info "App data   : $DATA_DIR"
  info "Icon       : ${ICON#$REPO_DIR/}"
fi
if (( TARGET_CLI )); then
  info "CLI        : $CLI_LAUNCHER"
  info "Agent home : $CLI_HOME"
fi

# ===========================================================================
step "Preflight: verify target assumptions"
# ===========================================================================
# Each adapter checks the structure it depends on (helper naming, framework
# layout, ...). Better to abort before touching anything than to silently produce
# an app that installs and doesn't work.
if (( TARGET_APP )); then
  a_preflight "$SRC" || die "Preflight failed — see \"When preflight fails\" in AGENTS.md"
fi
if (( TARGET_CLI )); then
  CLI_COMMAND_PATH="$(command -v "$A_CLI_COMMAND" 2>/dev/null || true)"
  [[ -n "$CLI_COMMAND_PATH" ]] ||
    die "${A_LABEL} CLI command '$A_CLI_COMMAND' was not found in PATH — install it before creating a CLI target"
  info "CLI command: $CLI_COMMAND_PATH"
  case ":$PATH:" in
    *":$CLI_BIN_REAL:"*) ;;
    *) warn "CLI launcher directory is not on PATH: $CLI_BIN_REAL" ;;
  esac
fi

# Informational only: these files are copied along with the bundle untouched.
if (( TARGET_APP )); then
  UNPACKED_DIR="$SRC/Contents/Resources/app.asar.unpacked"
  UNPACKED_COUNT=0
  [[ -d "$UNPACKED_DIR" ]] && UNPACKED_COUNT=$(find "$UNPACKED_DIR" -type f | wc -l | tr -d ' ')
  info "Files outside the asar: ${UNPACKED_COUNT} (copied as-is, never repacked)"
fi

# ===========================================================================
# The dry-run boundary: everything above is read-only; everything below touches
# the filesystem.
# ===========================================================================
if (( DRY_RUN )); then
  print -P "\n%F{yellow}--dry-run: stopping here, nothing was changed.%f"
  info "Without --dry-run it would go on to:"
  (( TARGET_APP )) && info "  - Quit any running ${NAME}, then safely rebuild and re-sign ${APP}"
  (( TARGET_CLI )) && info "  - Install isolated CLI launcher ${CLI_LAUNCHER}"
  info "  - Write the unified profile ${PROFILE#$REPO_DIR/}"
  exit 0
fi

if (( TARGET_APP )); then

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
step "Refreshing Launch Services / icon cache"
# ===========================================================================
"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" -f "$APP"
killall Dock 2>/dev/null || true
fi

# ==========================================================================
# CLI launcher: generated and maintained by this same engine and profile. It
# contains no credentials; it only selects the isolated state root.
# ==========================================================================
if (( TARGET_CLI )); then
  step "Installing isolated CLI launcher"
  mkdir -p -m 700 "$CLI_BIN_REAL"
  mkdir -p -m 700 "$CLI_HOME_REAL"
  umask 077
  {
    print '#!/bin/zsh'
    print "# Generated by clone-agent.sh for profile ${NAME}."
    a_cli_wrapper_env "$NAME"
    a_cli_exec
  } > "$CLI_LAUNCHER"
  chmod 700 "$CLI_LAUNCHER"
fi

# ===========================================================================
# Save the single profile used by both app and CLI targets.
# ===========================================================================
mkdir -p "$PROFILE_DIR"
icon_store="$ICON"
[[ "$icon_store" == "$REPO_DIR/"* ]] && icon_store="${icon_store#$REPO_DIR/}"
# Values must be written single-quoted (${(qq)} handles quoting and escaping).
# With double quotes, the literal $HOME in DATA_DIR would expand at source time
# into an absolute path, pinning the profile to the current user.
{
  print "# Generated by clone-agent.sh — app and CLI parameters for ${NAME}."
  print "# Rebuild with ./clone-agent.sh ${NAME} (or --all)."
  print "P_APP=${(qq)APP_KIND}"
  print "P_TARGET=${(qq)TARGET}"
  print "P_ICON=${(qq)icon_store}"
  print "P_BUNDLE_ID=${(qq)BUNDLE_ID}"
  print "P_DATA_DIR=${(qq)DATA_DIR}"
  print "P_SOURCE=${(qq)SRC}"
  print "P_DEST_DIR=${(qq)DEST_DIR}"
  print "P_CLI_NAME=${(qq)CLI_NAME}"
  print "P_CLI_BIN_DIR=${(qq)CLI_BIN_DIR}"
} > "$PROFILE"

print -P "\n%F{green}Done.%f"
if (( TARGET_APP )); then
  info "App      : $APP"
  info "Version  : $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)"
  info "App data : $DATA_DIR"
fi
if (( TARGET_CLI )); then
  info "CLI      : $CLI_LAUNCHER"
  info "CLI data : $CLI_HOME"
fi
info "Profile  : ${PROFILE#$REPO_DIR/}"
(( TARGET_APP )) && a_notes "$NAME"
(( TARGET_CLI )) && a_cli_notes "$NAME"
(( TARGET_APP )) && print "\nLaunch app: open \"$APP\""
(( TARGET_CLI )) && print "Launch CLI: $CLI_NAME"
print "Rebuild:  ./clone-agent.sh ${NAME}"
