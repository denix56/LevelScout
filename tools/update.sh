#!/bin/sh
# tools/update.sh: fetch the current ForeverDB addon data and rebuild LevelScout/data from it.
#
#   tools/update.sh            update when ForeverDB has published something newer, else do nothing
#   tools/update.sh --check    only say whether the baked data is behind (exit 1 when it is)
#   tools/update.sh --force    re-download nothing that is current, but re-run the import anyway
#   tools/update.sh --commit   after a successful update, commit LevelScout/data and the report
#
# What it does:
#   1. Reads https://foreverdb.net/downloads/addon-manifest.json (addon version, data version and
#      the SHA-256 of the addon zip and of every data file).
#   2. If the addon version changed, downloads the whole addon zip; then downloads every data file
#      whose checksum differs. Every download is checked against the manifest's SHA-256.
#   3. Swaps the result into local/sources/ForeverDB (the old copy is kept as ForeverDB.prev).
#   4. Runs tools/import/import.lua (ForeverDB only: QuestieDB is read by the addon at runtime),
#      compares the new counts with the previous report and runs the test suite. The real-data
#      tests load the installed QuestieDB addon; without it the tests are skipped with a warning
#      (run them later with QUESTIEDB=<folder> ./run_tests.sh).
#   5. If anything fails, puts the old source, data and report back and exits non-zero.
#
# Environment: QUESTIEDB (QuestieDB's addon folder, for the tests only), LUA (Lua 5.1), MAX_DROP
# (largest allowed fall of a count, in percent; default 5).
set -eu
cd "$(dirname "$0")/.."

SITE="https://foreverdb.net"
SRC="local/sources/ForeverDB"
DATA="LevelScout/data"
REPORT="tools/import/last_report.txt"
QUESTIEDB="${QUESTIEDB:-/Applications/World of Warcraft/_forever_/Interface/AddOns/QuestieDB}"
LUA="${LUA:-./.tools/bin/lua5.1}"
MAX_DROP="${MAX_DROP:-5}"

check=0 force=0 commit=0
for a in "$@"; do
    case "$a" in
        --check) check=1 ;;
        --force) force=1 ;;
        --commit) commit=1 ;;
        *) echo "usage: tools/update.sh [--check] [--force] [--commit]" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
fail() { printf 'update: %s\n' "$*" >&2; exit 1; }
for tool in curl jq unzip shasum; do
    command -v "$tool" >/dev/null 2>&1 || fail "needs '$tool'"
done
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
get() { curl -fsSL --max-time 300 -o "$2" "$1"; }

mkdir -p local/sources
work="$(mktemp -d local/sources/.update.XXXXXX)"
swapped=0
finish() {
    status=$?
    trap - EXIT
    if [ "$status" -ne 0 ] && [ "$swapped" -eq 1 ]; then
        say "update: failed; putting the previous data and ForeverDB source back" >&2
        rm -rf "$DATA" && cp -R "$work/data.bak" "$DATA"
        [ -f "$work/report.bak" ] && cp "$work/report.bak" "$REPORT"
        rm -rf "$SRC.failed"
        mv "$SRC" "$SRC.failed"
        [ -d "$SRC.prev" ] && mv "$SRC.prev" "$SRC"
        say "update: the rejected source is kept in $SRC.failed" >&2
    fi
    rm -rf "$work"
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- 1. what is published, what we have
get "$SITE/downloads/addon-manifest.json" "$work/manifest.json" || fail "cannot download the manifest from $SITE"
m() { jq -er "$1" "$work/manifest.json"; }
newAddon="$(m .addon.version)" && newData="$(m .data.version)" && zipUrl="$(m .addon.url)" && zipSha="$(m .addon.sha256)" \
    || fail "the manifest does not have the expected shape"
safeUrl() { case "$1" in *..*|/*|*://*) return 1 ;; downloads/*) return 0 ;; *) return 1 ;; esac; }
printf '%s' "$newAddon" | grep -Eq '^[0-9]+(\.[0-9]+){1,2}$' || fail "odd addon version in the manifest: $newAddon"
printf '%s' "$newData" | grep -Eq '^[0-9A-Za-z.-]+$' || fail "odd data version in the manifest: $newData"
safeUrl "$zipUrl" || fail "odd addon url in the manifest: $zipUrl"

field() { sed -n "s/^ *$1 = \"\\(.*\\)\",\$/\\1/p" "$DATA/Meta.lua" 2>/dev/null | head -1; }
bakedAddon="$(field ForeverDB)"
bakedData="$(field ForeverDBData)"
srcAddon="$(sed -n 's/^## Version: *//p' "$SRC/ForeverDB.toc" 2>/dev/null | tr -d '\r' | head -1)"
srcData="$(sed -n 's/.*ns\.meta *= *{.*version="\([^"]*\)".*/\1/p' "$SRC/Data/Meta.lua" 2>/dev/null | head -1)"

say "ForeverDB published:  addon $newAddon, data $newData"
say "local source copy:    addon ${srcAddon:-none}, data ${srcData:-none}"
say "baked into the mod:   addon ${bakedAddon:-unknown}, data ${bakedData:-unknown}"

if [ "$bakedAddon" = "$newAddon" ] && [ "$bakedData" = "$newData" ]; then
    say "The mod's data is current."
    [ "$force" -eq 1 ] && [ "$check" -eq 0 ] || exit 0
    say "--force: importing again."
else
    say "The mod's data is behind."
    [ "$check" -eq 0 ] || exit 1
fi

[ -x "$LUA" ] || fail "Lua 5.1 not found at $LUA (set LUA=...)"

# ---------------------------------------------------------------- 2. stage the new source
stage="$work/stage/ForeverDB"
mkdir -p "$work/stage"
if [ "$srcAddon" != "$newAddon" ] || [ ! -d "$SRC/Data" ]; then
    say "downloading the addon $newAddon ..."
    get "$SITE/$zipUrl" "$work/addon.zip" || fail "cannot download $SITE/$zipUrl"
    [ "$(sha "$work/addon.zip")" = "$zipSha" ] || fail "the addon zip does not match the manifest's SHA-256"
    if unzip -Z1 "$work/addon.zip" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then fail "the addon zip has unsafe paths"; fi
    mkdir "$work/zip"
    unzip -q "$work/addon.zip" -d "$work/zip"
    [ -f "$work/zip/ForeverDB/ForeverDB.toc" ] || fail "the addon zip has no ForeverDB/ForeverDB.toc"
    mv "$work/zip/ForeverDB" "$stage"
else
    cp -R "$SRC" "$stage"
fi

jq -r '.data.files[] | [.path, .url, .sha256] | @tsv' "$work/manifest.json" > "$work/files.tsv" \
    || fail "the manifest's data file list does not have the expected shape"
mkdir "$work/dl"
fetched=0
tab="$(printf '\t')"
while IFS="$tab" read -r path url want; do
    printf '%s' "$path" | grep -Eq '^Data/[A-Za-z0-9_]+\.lua$' || fail "odd data file path in the manifest: $path"
    safeUrl "$url" || fail "odd data file url in the manifest: $url"
    if [ -f "$stage/$path" ] && [ "$(sha "$stage/$path")" = "$want" ]; then continue; fi
    name="${path#Data/}"
    get "$SITE/$url" "$work/dl/$name" || fail "cannot download $SITE/$url"
    [ "$(sha "$work/dl/$name")" = "$want" ] || fail "$path does not match the manifest's SHA-256"
    mv "$work/dl/$name" "$stage/$path"
    fetched=$((fetched + 1))
done < "$work/files.tsv"
say "data files downloaded: $fetched"

stagedData="$(sed -n 's/.*ns\.meta *= *{.*version="\([^"]*\)".*/\1/p' "$stage/Data/Meta.lua" | head -1)"
[ "$stagedData" = "$newData" ] || fail "the downloaded data says version '$stagedData', the manifest says '$newData'"

# ---------------------------------------------------------------- 3. swap it in, keeping the old one
cp -R "$DATA" "$work/data.bak"
[ -f "$REPORT" ] && cp "$REPORT" "$work/report.bak"
rm -rf "$SRC.prev"
[ -d "$SRC" ] && mv "$SRC" "$SRC.prev"
mv "$stage" "$SRC"
swapped=1

# ---------------------------------------------------------------- 4. import, compare, test
say "importing ..."
"$LUA" tools/import/import.lua --foreverdb "$SRC" > "$work/import.out"

if [ -f "$work/report.bak" ]; then
    say "counts that changed:"
    awk -v maxdrop="$MAX_DROP" '
            function counts(line) { return line ~ /^  [^ ]/ && line ~ / [0-9]+$/ }
            /^counts:/ { on = 1; next }
            on && !counts($0) { on = 0 }
            on {
                value = $NF; name = $0; sub(/ +[0-9]+$/, "", name); sub(/^ +/, "", name)
                if (FNR == NR) { old[name] = value; next }
                seen[name] = 1
                if (!(name in old)) { printf "  %-45s new  %d\n", name, value; next }
                if (old[name] != value) printf "  %-45s %d -> %d\n", name, old[name], value
                if (old[name] >= 100 && value < old[name] * (1 - maxdrop / 100)) { printf "    ^ fell by more than %s%%\n", maxdrop; bad = 1 }
            }
            END {
                for (name in old) if (!(name in seen)) { printf "  %-45s gone (was %d)\n", name, old[name]; if (old[name] >= 100) bad = 1 }
                exit bad
            }' "$work/report.bak" "$REPORT" || fail "a count fell sharply (allow it with MAX_DROP=<percent>)"
fi

if [ -f "$QUESTIEDB/QuestieDB_Forever.toc" ]; then
    say "running the tests (about a minute) ..."
    if ! QUESTIEDB="$QUESTIEDB" ./run_tests.sh -j 4 > "$work/tests.out" 2>&1; then
        tail -40 "$work/tests.out" >&2
        fail "the tests fail on the new data"
    fi
    tail -1 "$work/tests.out"
else
    say "WARNING: tests not run: the real-data tests need the QuestieDB addon, not found at $QUESTIEDB"
    say "         (run them before committing: QUESTIEDB=<QuestieDB folder> ./run_tests.sh -j 4)"
fi

# ---------------------------------------------------------------- 5. done
swapped=0
rm -rf "$SRC.failed"
say "Updated: ForeverDB addon $newAddon, data $newData."
if [ "$commit" -eq 1 ]; then
    git add -- "$DATA" "$REPORT"
    if git diff --cached --quiet -- "$DATA" "$REPORT"; then
        say "nothing to commit: the generated files did not change"
    else
        git commit -q -m "Data: ForeverDB $newAddon, data $newData" -- "$DATA" "$REPORT"
        say "committed: $(git log --oneline -1)"
    fi
else
    say "Not committed. Review with: git status --short"
fi
