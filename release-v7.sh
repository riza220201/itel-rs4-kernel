#!/usr/bin/env bash
# Create the v7 GitHub release (as a DRAFT) + upload all assets via the GitHub REST
# API — no `gh` needed, reuses your classic PAT (needs `repo` scope, same as your git
# push). Review the draft on GitHub, then hit Publish.
#
#   GH_TOKEN=<your-classic-PAT> bash release-v7.sh
#
# v7 is a RE-ISSUE: the first v7 release was deleted, and the tag was moved to the
# fixed commit. This refuses to run unless the remote tag v7 is the local tag v7, so
# the release can never attach to the old (pulled) source.
set -euo pipefail
REPO="riza220201/itel-rs4-kernel"
TAG="v7"
TITLE="Riza Kernel — Itel RS4 (S666LN) — v7"
NOTES="out/RELEASE-NOTES-v7.md"
DATE="20260928"
: "${GH_TOKEN:?set GH_TOKEN=<your PAT with repo scope>}"
ASSETS=(
  out/vanilla/ItelRS4-Kernel-vanilla-$DATE.zip
  out/vanilla/ItelRS4-boot-vanilla-$DATE.img
  out/ksunext/ItelRS4-Kernel-ksunext-$DATE.zip
  out/ksunext/ItelRS4-boot-ksunext-$DATE.img
  out/kowsu/ItelRS4-Kernel-kowsu-$DATE.zip
  out/kowsu/ItelRS4-boot-kowsu-$DATE.img
)
for f in "$NOTES" "${ASSETS[@]}"; do [[ -f "$f" ]] || { echo "✗ missing: $f"; exit 1; }; done

local_tag=$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" || true)
remote_tag=$(git ls-remote origin "refs/tags/$TAG^{}" "refs/tags/$TAG" | awk 'NR==1{print $1}')
remote_peeled=$(git ls-remote origin "refs/tags/$TAG^{}" | awk '{print $1}')
[[ -n "$remote_peeled" ]] && remote_tag="$remote_peeled"
[[ -n "$local_tag" && "$local_tag" == "$remote_tag" ]] \
  || { echo "✗ tag $TAG: local ${local_tag:-none} != remote ${remote_tag:-none} — push the moved tag first"; exit 1; }
echo "✓ tag $TAG -> ${local_tag:0:12} on both sides"

# SHA256SUMS over exactly the assets being published
( cd out && sha256sum "${ASSETS[@]#out/}" ) > out/SHA256SUMS
ASSETS+=(out/SHA256SUMS)
cat out/SHA256SUMS

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
