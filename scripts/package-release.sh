#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEVUI_BIN="$ROOT/u60pro-devui.stripped"
DATAD_BIN=
OUT="$ROOT/dist/v1.2.12-remix.6"

usage() {
    echo "usage: $0 --datad PATH [--devui PATH] [--out DIR]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --datad) [ $# -ge 2 ] || usage; DATAD_BIN=$2; shift 2 ;;
        --devui) [ $# -ge 2 ] || usage; DEVUI_BIN=$2; shift 2 ;;
        --out) [ $# -ge 2 ] || usage; OUT=$2; shift 2 ;;
        *) usage ;;
    esac
done

[ -n "$DATAD_BIN" ] || usage
[ -f "$DEVUI_BIN" ] || { echo "missing DevUI binary: $DEVUI_BIN" >&2; exit 1; }
[ -f "$DATAD_BIN" ] || { echo "missing datad binary: $DATAD_BIN" >&2; exit 1; }
[ -x "$ROOT/scripts/cpuctl.sh" ] || { echo "cpuctl.sh must be executable" >&2; exit 1; }

case "$OUT" in
    /*) ;;
    *) OUT="$ROOT/$OUT" ;;
esac

for bin in "$DEVUI_BIN" "$DATAD_BIN"; do
    info=$(file "$bin")
    echo "$info"
    echo "$info" | grep -Eiq 'ELF 64-bit.*(ARM aarch64|aarch64)'
    echo "$info" | grep -Eiq 'static|statically linked'
done

rm -rf "$OUT"
mkdir -p "$OUT" "$OUT/.ui-stage/functions"
cp "$DEVUI_BIN" "$OUT/u60pro-devui-aarch64"
cp "$DATAD_BIN" "$OUT/zwrt-datad-aarch64"
chmod 755 "$OUT/u60pro-devui-aarch64" "$OUT/zwrt-datad-aarch64"

cp "$ROOT"/ui/*.html "$ROOT"/ui/*.css "$OUT/.ui-stage/"
cp -R "$ROOT/ui/subpages" "$OUT/.ui-stage/subpages"
cp -R "$ROOT/ui/functions"/. "$OUT/.ui-stage/functions/"
cp "$ROOT/scripts/cpuctl.sh" "$OUT/.ui-stage/functions/cpuctl.sh"
chmod 755 "$OUT/.ui-stage/functions/cpuctl.sh"

(
    cd "$OUT/.ui-stage"
    COPYFILE_DISABLE=1 tar -czf "$OUT/ui.tar.gz" -- *.html *.css subpages functions
)

tar -tzf "$OUT/ui.tar.gz" > "$OUT/.tar-list"
grep -qx '01-signal.html' "$OUT/.tar-list"
grep -qx '02-functions.html' "$OUT/.tar-list"
grep -qx 'style.css' "$OUT/.tar-list"
grep -qx 'functions/cpuctl.sh' "$OUT/.tar-list"
for page in tailscale clash cpu-performance wireguard operator-lock; do
    grep -qx "functions/$page.html" "$OUT/.tar-list"
done
grep -q '^subpages/.*\.html$' "$OUT/.tar-list"
if grep -Eq '^(\./|ui/)|(^|/)\._' "$OUT/.tar-list"; then
    echo "invalid ui.tar.gz path layout" >&2
    exit 1
fi
tar -tvzf "$OUT/ui.tar.gz" | grep -Eq '^-rwx[^ ]* .* functions/cpuctl\.sh$'

cp "$ROOT/version.json" "$OUT/version.json"
python3 - "$OUT/version.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
assert data["schema"] == 1
assert set(("datad", "devui", "ui")) <= data.keys()
assert data["datad"]["asset"] == "zwrt-datad-aarch64"
assert data["devui"]["asset"] == "u60pro-devui-aarch64"
assert data["ui"]["asset"] == "ui.tar.gz"
PY

(
    cd "$OUT"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum version.json zwrt-datad-aarch64 u60pro-devui-aarch64 ui.tar.gz > SHA256SUMS
    else
        shasum -a 256 version.json zwrt-datad-aarch64 u60pro-devui-aarch64 ui.tar.gz > SHA256SUMS
    fi
)

rm -rf "$OUT/.ui-stage" "$OUT/.tar-list"
echo "release assets: $OUT"
ls -lh "$OUT"
