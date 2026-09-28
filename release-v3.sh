#!/usr/bin/env bash
# Create the v3 GitHub release (as a DRAFT) + upload all assets via the GitHub REST
# API — no `gh` needed, reuses your existing classic PAT (needs `repo` scope, same as
# your git push). Review the draft on GitHub, then hit Publish.
#
#   GH_TOKEN=<your-classic-PAT> bash release-v3.sh
#
set -euo pipefail
REPO="riza220201/itel-rs4-kernel"
TAG="v3"
TITLE="Riza Kernel — Itel RS4 (S666LN) — v3"
NOTES="out/RELEASE-NOTES-v3.md"
: "${GH_TOKEN:?set GH_TOKEN=<your PAT with repo scope>}"
ASSETS=(
  out/vanilla/ItelRS4-Kernel-vanilla-20260715.zip
  out/vanilla/ItelRS4-boot-vanilla-20260715.img
  out/ksunext/ItelRS4-Kernel-ksunext-20260715.zip
  out/ksunext/ItelRS4-boot-ksunext-20260715.img
  out/kowsu/ItelRS4-Kernel-kowsu-20260715.zip
  out/kowsu/ItelRS4-boot-kowsu-20260715.img
  out/SHA256SUMS
)
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
