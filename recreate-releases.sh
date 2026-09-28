#!/usr/bin/env bash
# Recreate every GitHub release after the repo was deleted and re-pushed.
#
#   GH_TOKEN=<classic PAT with repo scope> bash recreate-releases.sh
#
# v1-v4 come from backup/ (assets downloaded before the delete, release.txt =
# the original release notes). v5 comes from out/, which was never lost.
# Releases are created as DRAFTS — review them on GitHub, then Publish.
set -euo pipefail
REPO="riza220201/itel-rs4-kernel"
: "${GH_TOKEN:?set GH_TOKEN=<your PAT with repo scope>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

api() { curl -fsS -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

make_release() { # $1 tag  $2 title  $3 notes-file  $4... assets
  local tag="$1" title="$2" notes="$3"; shift 3
  [ -f "$notes" ] || { echo "!! missing notes: $notes"; return 1; }
  echo "== $tag =="
  local payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tag_name":sys.argv[1],"name":sys.argv[2],"body":open(sys.argv[3]).read(),"draft":True}))' "$tag" "$title" "$notes")
  local rid
  rid=$(api -X POST "https://api.github.com/repos/$REPO/releases" -d "$payload" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  echo "   draft id=$rid"
  local f name ct
  for f in "$@"; do
    [ -f "$f" ] || { echo "   !! missing asset: $f"; continue; }
    name=$(basename "$f"); ct="application/octet-stream"
    case "$f" in *.zip) ct="application/zip";; *.txt|*.md) ct="text/plain";; esac
    echo "   up $name ($(du -h "$f" | cut -f1))"
    curl -fsS -X POST "https://uploads.github.com/repos/$REPO/releases/$rid/assets?name=$name" \
      -H "Authorization: Bearer $GH_TOKEN" -H "Content-Type: $ct" \
      --data-binary @"$f" >/dev/null
  done
}

for v in 1 2 3 4; do
  d="$HERE/backup/v$v"
  [ -d "$d" ] || { echo "skip v$v (no backup dir)"; continue; }
  # shellcheck disable=SC2046
  make_release "V$v" "Riza Kernel — Itel RS4 (S666LN) — v$v" "$d/release.txt" \
    $(ls "$d"/*.img "$d"/*.zip "$d"/SHA256SUMS 2>/dev/null)
done

# v5 — assets never left the machine.
V5=""
for f in "$HERE"/out/vanilla/*20260728* "$HERE"/out/ksunext/*20260728* "$HERE"/out/kowsu/*20260728* "$HERE"/out/SHA256SUMS; do
  [ -f "$f" ] && V5="$V5 $f"
done
# shellcheck disable=SC2086
make_release "v5" "Riza Kernel — Itel RS4 (S666LN) — v5" "$HERE/out/RELEASE-NOTES-v5.md" $V5

echo
echo "All releases created as DRAFTS. Review and Publish at:"
echo "  https://github.com/$REPO/releases"
