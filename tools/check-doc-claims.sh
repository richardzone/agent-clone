#!/bin/zsh
# Check the claims AGENTS.md makes about this repo's own code.
#
# Why this exists: section 15 used to cite the engine by line number. Every one
# of those citations silently pointed at a different real line the moment the
# engine moved — a comment, a banner separator — which is how two rounds of
# review found claims that "checked out" against the wrong line. Anchors here
# are source fragments instead: one that stops matching fails loudly and names
# the claim to revisit, which a line number can never do.
#
# Add an anchor whenever the docs describe engine behaviour. Keep the fragment
# short enough to survive reformatting and specific enough to be unique — the
# uniqueness check below enforces the second half.
set -u
cd "${0:A:h}/.."

ENGINE=clone-agent.sh
DOC=AGENTS.md
fail=0
note() { print -P "  %F{red}FAIL%f $1"; fail=1 }
ok()   { print -P "  %F{green}ok%f   $1" }

# <file> § <source fragment> § <the claim it backs>
anchors=(
  "$ENGINE§ICON=\"\$REPO_DIR/\$ICON\"§relative icons re-root to the repo"
  "$ENGINE§for _p in \"\$PROFILE_DIR\"/*.conf§bundle-ID guard scans profiles"
  "$ENGINE§for _app in \"\$DEST_DIR\"/*.app§second guard scans the dest dir"
  "$ENGINE§mkdir -p \"\$PROFILE_DIR\"§profile write is unconditional"
  "$ENGINE§} > \"\$PROFILE\"§profile write truncates"
  "$ENGINE§print \"P_TARGET=§a named run rewrites the stored target"
  "$ENGINE§(( TARGET_SET )) &&§--all refuses --target"
  "$ENGINE§lsregister§app targets refresh Launch Services"
  "$ENGINE§killall Dock§app targets restart the Dock"
  "$ENGINE§cp -R \"\$SRC\" \"\$APP\"§the source copy"
  "$ENGINE§: \${TARGET:=all}§omitting --target selects the widest target"
  "$ENGINE§: \${DEST_DIR:=\"/Applications\"}§omitting --dest-dir aims at /Applications"
  "$ENGINE§patch-asar-integrity-digest.js\" --check \"\$SRC\" ||§preflight checks the embedded integrity slot, and refuses"
  "$ENGINE§die \"Preflight failed: embedded ASAR integrity digest§a failed digest check stops the run"
  "$ENGINE§node is required for app targets§preflight names a broken node"
  "$ENGINE§patch-asar-integrity-digest.js\" \"\$APP\"§step 7 re-syncs the embedded integrity digest"
  "adapters/codex.sh§CODEX_HOME=\"\$tmp\" codex§codex preflight runs the vendor binary"
  "adapters/claude.sh§a_cli_preflight() { :; }§claude's preflight is a no-op"
)
# Section 13's codex-layout claims: where the bundled codex lives, how the adapter
# and the launcher choose it (one shared test), what preflight refuses, and that
# the launcher appends rather than prepends to PATH.
CODEX=adapters/codex.sh
LAUNCHER=tools/codex-cli-launcher.cjs
anchors+=(
  "$CODEX§_A_CODEX_CLI_APP='Contents/Resources/codex-cli/CodexCLI.app'§the nested-bundle path"
  "$CODEX§_A_CODEX_BARE='Contents/Resources/codex'§the pre-26.928 bare path"
  "$CODEX§_a_codex_signed() {§the adapter's layout chooser"
  "$CODEX§[[ -f \"\$nested\" && -x \"\$nested\" ]]§the adapter's regular-executable test"
  "$CODEX§Missing bundled codex executable§the missing-codex refusal"
  "$CODEX§-R='anchor apple generic' \"\$codex_app\"§preflight refuses an unsigned/ad-hoc codex"
  "$CODEX§-R='anchor apple generic' \"\$codex_signed\"§the post-copy seal assertion"
  "$LAUNCHER§isExecutableFile(bundledCodex)§the launcher applies the same test"
  "$LAUNCHER§\${currentPath}\${path.delimiter}\${codexDir}§the launcher appends to PATH"
)
# The messages "When preflight fails" quotes, each anchored where it is printed.
DIGEST=tools/patch-asar-integrity-digest.js
anchors+=(
  "$CODEX§has no valid Apple-issued signature — reinstall the source app§the seal refusal"
  "$CODEX§   codesign: \${why%%§the seal refusal shows codesign's first line"
  "$CODEX§is present but not an executable regular file§the broken-install hint"
  "$CODEX§, or \${_A_CODEX_BARE#Contents/} before 26.928)§the missing-codex message names both paths"
  "$DIGEST§disappeared while being read§the mid-scan change refusal"
  "$DIGEST§stored integrity digest does not match this plist§the formula/modified refusal"
  'clone-agent.sh§embedded ASAR integrity digest — see \"When preflight fails\"§the digest die points at "When preflight fails"'
)

print "anchors"
for a in $anchors; do
  f="${a%%§*}"; rest="${a#*§}"; frag="${rest%%§*}"; what="${rest#*§}"
  n=$(grep -cF -- "$frag" "$f" 2>/dev/null)
  [[ -n "$n" ]] || n=0
  if   (( n == 0 )); then note "$what — \"$frag\" is no longer in $f"
  elif (( n > 1 ));  then note "$what — \"$frag\" matches $n lines in $f; narrow it"
  else ok "$what"
  fi
done

# The anchors above only prove the fragment is still in the engine. That is half
# the job: the doc's copy of it can drift independently, and a check that lets
# section 15 be gutted while reporting success is worse than none. So assert the
# doc still says the things those anchors back.
print "\ndoc still makes the claims the anchors back"
doc_must=(
  'for _p in "$PROFILE_DIR"/*.conf§the bundle-ID guard citation'
  'for _app in "$DEST_DIR"/*.app§the dest-dir guard citation'
  'mkdir -p "$PROFILE_DIR"§the profile-write quote'
  '> "$PROFILE"§the truncation quote'
  'ICON="$REPO_DIR/$ICON"§the icon re-rooting citation'
  'P_TARGET=${(qq)TARGET}§the silent target-rewrite quote'
  '(( TARGET_SET )) &&§the --all guard quote'
  'cp -R "$SRC" "$APP"§the source-copy boundary claim'
)
# These two the doc states in prose rather than quoting, so assert the prose.
# The engine side is covered by the anchors above.
doc_must+=(
  '`--target` defaults to `all`§the widest-default claim'
  '`--dest-dir` to `/Applications`§the dest-dir default claim'
  '**Preflight, `--check "$SRC"`**§the embedded-digest preflight claim'
  '**Step 7, right after the plist write**§the embedded-digest step-7 claim'
  'node is required for app targets§the broken-node message quote'
  '`_A_CODEX_CLI_APP` and `_A_CODEX_BARE`§the codex-layout paths quote'
  '`_a_codex_signed` picks whichever§the layout-chooser claim'
  '`tools/test-codex-layout.sh` asserts they agree§the adapter/launcher agreement claim'
  'preflight stops with `Missing bundled codex executable`§the missing-codex message quote'
  "\`codesign --verify --strict -R='anchor apple generic'\`§the preflight seal-check quote"
  'The app **appends** `dirname(CODEX_CLI_PATH)`§the append-not-prepend claim'
  'the `.cjs` launcher appends the `CodexCLI.app/Contents/MacOS`§the launcher-appends claim'
  '`Resources/codex` before 26.928, is the deliberate exception§section 5 names the bare layout'
  '`access(2)` `X_OK`§the shared executable-test definition'
  'has no valid Apple-issued signature — reinstall the source app§the seal refusal quote'
  'is present but not an executable regular file§the broken-install hint quote'
  '`stored integrity digest does not match this plist`§the formula/modified refusal quote'
  'disappeared while being read§the mid-scan change quote'
  '`node is required for app targets`** — see section 15§the node refusal points at section 15'
  '`Missing bundled codex executable`** names both paths§the missing-codex both-paths claim'
)
for d in $doc_must; do
  frag="${d%%§*}"; what="${d#*§}"
  grep -qF -- "$frag" "$DOC" && ok "$what" \
    || note "$what is gone from $DOC — the anchor now guards nothing"
done

# Claims and commands in the other docs that the codex-layout and digest work
# depends on: the keychain note for both layouts, the by-hand loop's digest step,
# and the two regression scripts in CONTRIBUTING's required checks.
print "\nother docs"
other_docs=(
  'README.md§(`Contents/Resources/codex` before 26.928)§README keychain note names the bare layout'
  'adapters/codex.sh§(Contents/Resources/codex before 26.928;§adapter keychain note names the bare layout'
  'adapters/README.md§the digest embedded in the framework binary§the by-hand loop syncs the embedded digest'
  'CONTRIBUTING.md§node tools/test-patch-asar-integrity-digest.js§CONTRIBUTING runs the digest tests'
  'CONTRIBUTING.md§zsh -f tools/test-codex-layout.sh§CONTRIBUTING runs the layout tests'
)
for d in $other_docs; do
  f="${d%%§*}"; rest="${d#*§}"; frag="${rest%%§*}"; what="${rest#*§}"
  grep -qF -- "$frag" "$f" 2>/dev/null && ok "$what" || note "$what — \"$frag\" is gone from $f"
done

# Load-bearing structure. Each of these has been deleted or inverted by a real
# edit at some point in this file's history.
print "\nsection 15 still contains its load-bearing parts"
struct=(
  '| Never touch | Why |§the never-touch table'
  'Every non-dry-run§the unconditional-write framing'
  'The list is open; these are the ones that bite§the un-redirectable list'
  'cannot be sandboxed by flags at all§the --all warning'
  'cannot be sandboxed either§the --init warning'
  'SbxName --dry-run§--dry-run first in the app block'
  'is the only fully contained§§ABSENT§the retracted "fully contained" claim'
)
for s in $struct; do
  if [[ "$s" == *'§§ABSENT§'* ]]; then
    frag="${s%%§§ABSENT§*}"; what="${s##*§}"
    grep -qF -- "$frag" "$DOC" && note "$what came back" || ok "$what stays retracted"
  else
    frag="${s%%§*}"; what="${s#*§}"
    grep -qF -- "$frag" "$DOC" && ok "$what" || note "$what is missing from $DOC"
  fi
done
n15=$(awk '/^## 15\./{f=1} /^## 16\./{f=0} f' "$DOC" | wc -l | tr -d ' ')
(( n15 > 150 )) && ok "section 15 is still substantive ($n15 lines)" \
                || note "section 15 shrank to $n15 lines — was it gutted?"

print "\nordering (which side of the dry-run boundary things sit on)"
pre=$(grep -n 'a_cli_preflight .. die' "$ENGINE" | cut -d: -f1)
bnd=$(grep -nF 'dry-run: stopping here' "$ENGINE" | cut -d: -f1)
cpy=$(grep -nF 'cp -R "$SRC" "$APP"' "$ENGINE" | cut -d: -f1)
lsr=$(grep -nF 'lsregister' "$ENGINE" | head -1 | cut -d: -f1)
dck=$(grep -nF 'patch-asar-integrity-digest.js" --check' "$ENGINE" | head -1 | cut -d: -f1)
dpt=$(grep -nF 'patch-asar-integrity-digest.js" "$APP"' "$ENGINE" | head -1 | cut -d: -f1)
ndv=$(grep -nF 'node --version' "$ENGINE" | head -1 | cut -d: -f1)
if [[ -z "$pre" || -z "$bnd" || -z "$cpy" || -z "$lsr" || -z "$dck" || -z "$dpt" || -z "$ndv" ]]; then
  note "could not locate one of the ordering anchors"
else
  (( pre < bnd )) && ok "codex preflight runs above the boundary" \
                  || note "preflight ($pre) is no longer above the boundary ($bnd)"
  (( dck < bnd )) && ok "the embedded-digest check runs above the boundary" \
                  || note "digest --check ($dck) is no longer above the boundary ($bnd)"
  (( dpt > cpy )) && ok "the embedded-digest patch runs on the copy, not the source" \
                  || note "digest patch ($dpt) no longer comes after the copy ($cpy)"
  (( ndv < dck )) && ok "node is checked before preflight first uses it" \
                  || note "node --version ($ndv) no longer precedes the digest --check ($dck)"
  (( cpy > bnd )) && ok "the source copy is past the boundary" \
                  || note "cp -R ($cpy) is no longer past the boundary ($bnd)"
  (( lsr > bnd )) && ok "lsregister / killall Dock are past the boundary" \
                  || note "lsregister ($lsr) is no longer past the boundary ($bnd)"
fi

# Claims AGENTS.md makes about other parts of AGENTS.md. The defect that
# prompted this check was one of these: section 15 described the verification
# checklist's grep, the checklist was changed, the description was left behind.
print "\nintra-document"
# Anchor on the checklist's actual command — the one that reads the keychain
# file — not on the first mention of `security`, which is section 15 quoting it.
kc=$(grep -F 'login.keychain-db' "$DOC" | head -1)
if [[ -z "$kc" ]]; then
  note "cannot find the keychain checklist command to compare against"
elif [[ "$kc" == *codex* ]] && grep -q 'greps .claude., so it sees none' "$DOC"; then
  note "section 15 says the checklist greps only claude; the checklist greps codex too"
elif [[ "$kc" != *codex* ]] && ! grep -q 'greps .claude., so it sees none' "$DOC"; then
  note "the checklist no longer greps codex, but section 15 no longer says so either"
else
  ok "the keychain checklist and its description agree"
fi
missing=0
for n in {1..16}; do
  grep -q "^## ${n}\. " "$DOC" || { note "section $n heading is missing"; missing=1 }
done
(( missing )) || ok "sections 1-16 all present"
grep -qE 'clone-agent\.sh:[0-9]' "$DOC" \
  && note "a line-number citation crept back in — cite a source fragment instead" \
  || ok "no line-number citations"

print ""
if (( fail )); then
  print -P "%F{red}doc claims are out of date — fix the doc or the anchor above%f"
  exit 1
fi
print -P "%F{green}all doc claims check out%f"
