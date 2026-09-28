#!/usr/bin/env bash
# Create the v6 GitHub release (as a DRAFT) + upload all assets via the GitHub REST
# API — no `gh` needed, reuses your existing classic PAT (needs `repo` scope, same as
# your git push). Review the draft on GitHub, then hit Publish.
#
#   GH_TOKEN=<your-classic-PAT> bash release-v6.sh
#
set -euo pipefail
REPO="riza220201/itel-rs4-kernel"
TAG="v6"
TITLE="Riza Kernel — Itel RS4 (S666LN) — v6"
NOTES="out/RELEASE-NOTES-v6.md"
DATE="20260903"
: "${GH_TOKEN:?set GH_TOKEN=<your PAT with repo scope>}"
ASSETS=(
  out/vanilla/ItelRS4-Kernel-vanilla-$DATE.zip
  out/vanilla/ItelRS4-boot-vanilla-$DATE.img
  out/ksunext/ItelRS4-Kernel-ksunext-$DATE.zip
  out/ksunext/ItelRS4-boot-ksunext-$DATE.img
  out/kowsu/ItelRS4-Kernel-kowsu-$DATE.zip
  out/kowsu/ItelRS4-boot-kowsu-$DATE.img
  out/SHA256SUMS
)
# NOTE: the ntsync SELinux helper module is NOT re-attached here — it is unchanged
# since v4 and stays archived on the v4 release. Its source is in
# ntsync-selinux-module/ if it ever needs rebuilding.
for f in "$NOTES" "${ASSETS[@]}"; do [[ -f "$f" ]] || { echo "✗ missing: $f"; exit 1; }; done

# 1) create the release (draft)
payload=$(python3 -c 'import json,sys; print(json.dumps({"tag_name":sys.argv[1],"name":sys.argv[2],"body":open(sys.argv[3]).read(),"draft":True}))' "$TAG" "$TITLE" "$NOTES")
resp=$(curl -fsS -X POST "https://api.github.com/repos/$REPO/releases" \
  -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
  -d "$payload")
rel_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$resp")
echo "✓ draft release created (id=$rel_id)"

# 2) upload each asset
for f in "${ASSETS[@]}"; do
  name=$(basename "$f")
  ct="application/octet-stream"; [[ "$f" == *.zip ]] && ct="application/zip"
  echo "  ↑ $name"
  curl -fsS -X POST "https://uploads.github.com/repos/$REPO/releases/$rel_id/assets?name=$name" \
    -H "Authorization: Bearer $GH_TOKEN" -H "Content-Type: $ct" \
    --data-binary @"$f" >/dev/null
done
echo "✓ all assets uploaded — review + Publish the DRAFT at:"
echo "  https://github.com/$REPO/releases"
