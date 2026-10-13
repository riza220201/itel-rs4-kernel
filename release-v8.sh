#!/usr/bin/env bash
# Create the v8 GitHub release (as a DRAFT) + upload all assets via the GitHub REST
# API. Uses GH_TOKEN if set, else the token `gh` is logged in with (needs `repo` scope).
# Review the draft on GitHub, then hit Publish.
#
#   bash release-v8.sh            (or GH_TOKEN=<your-classic-PAT> bash release-v8.sh)
#
# No tag is pushed: the draft names tag v8 + the commit the v8 binaries were built
# from, and GitHub creates the tag only when the draft is PUBLISHED. Refuses to run if
# that commit is not on origin/main, if a remote v8 tag points elsewhere, or if a v8
# release (draft or not) already exists.
set -euo pipefail
REPO="riza220201/itel-rs4-kernel"
TAG="v8"
TARGET="fb6c55799e320233f53ff1f3be824e39fb0733d5"   # "v8: rs4_sec_tsp, hid-sony DS4-clone fallbacks, KoWSU b9f852d6"
TITLE="Riza Kernel — Itel RS4 (S666LN) — v8"
NOTES="out/RELEASE-NOTES-v8.md"
DATE="20261013"
GH_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null || true)}"
: "${GH_TOKEN:?set GH_TOKEN=<your PAT with repo scope>, or log in with gh}"
ASSETS=(
  out/vanilla/ItelRS4-Kernel-vanilla-$DATE.zip
  out/vanilla/ItelRS4-boot-vanilla-$DATE.img
  out/ksunext/ItelRS4-Kernel-ksunext-$DATE.zip
  out/ksunext/ItelRS4-boot-ksunext-$DATE.img
  out/kowsu/ItelRS4-Kernel-kowsu-$DATE.zip
  out/kowsu/ItelRS4-boot-kowsu-$DATE.img
)
for f in "$NOTES" "${ASSETS[@]}"; do [[ -f "$f" ]] || { echo "✗ missing: $f"; exit 1; }; done

git fetch -q origin main
git merge-base --is-ancestor "$TARGET" origin/main \
  || { echo "✗ $TARGET is not on origin/main — push it first"; exit 1; }
remote_tag=$(git ls-remote origin "refs/tags/$TAG^{}" | awk '{print $1}')
[[ -n "$remote_tag" ]] || remote_tag=$(git ls-remote origin "refs/tags/$TAG" | awk '{print $1}')
[[ -z "$remote_tag" || "$remote_tag" == "$TARGET" ]] \
  || { echo "✗ remote tag $TAG -> $remote_tag, not $TARGET"; exit 1; }
existing=$(curl -fsS "https://api.github.com/repos/$REPO/releases?per_page=100" \
  -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
  | python3 -c 'import json,sys; t=sys.argv[1]; print(" ".join(str(r["id"]) for r in json.load(sys.stdin) if r["tag_name"]==t))' "$TAG")
[[ -z "$existing" ]] || { echo "✗ a $TAG release already exists (id $existing) — delete it or edit it on GitHub"; exit 1; }
echo "✓ $TAG -> ${TARGET:0:12} (on origin/main; tag ${remote_tag:+exists}${remote_tag:-created on Publish})"

# SHA256SUMS over exactly the assets being published
( cd out && sha256sum "${ASSETS[@]#out/}" ) > out/SHA256SUMS
ASSETS+=(out/SHA256SUMS)
cat out/SHA256SUMS

# 1) create the release (draft)
payload=$(python3 -c 'import json,sys; print(json.dumps({"tag_name":sys.argv[1],"target_commitish":sys.argv[2],"name":sys.argv[3],"body":open(sys.argv[4]).read(),"draft":True}))' "$TAG" "$TARGET" "$TITLE" "$NOTES")
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
