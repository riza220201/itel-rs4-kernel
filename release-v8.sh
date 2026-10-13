#!/usr/bin/env bash
# Create — or refresh — the v8 GitHub release DRAFT and upload all assets via the GitHub
# REST API. Uses GH_TOKEN if set, else the token `gh` is logged in with (`repo` scope).
# Review the draft on GitHub, then hit Publish.
#
#   bash release-v8.sh            (or GH_TOKEN=<your-classic-PAT> bash release-v8.sh)
#
# No tag is pushed: the draft names tag v8 + TARGET (HEAD, which must already be on
# origin/main with no uncommitted build inputs), and GitHub creates the tag only when the
# draft is PUBLISHED. An existing v8 DRAFT is updated in place (target, notes, every asset
# replaced); a PUBLISHED v8 release is never touched.
set -euo pipefail
REPO="riza220201/itel-rs4-kernel"
TAG="v8"
TARGET="$(git rev-parse HEAD)"
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
git diff --quiet HEAD -- sources.lock build.sh package.sh config patches 'apply-*.sh' \
  || { echo "✗ uncommitted build inputs — the tag would not describe the binaries"; exit 1; }
remote_tag=$(git ls-remote origin "refs/tags/$TAG^{}" | awk '{print $1}')
[[ -n "$remote_tag" ]] || remote_tag=$(git ls-remote origin "refs/tags/$TAG" | awk '{print $1}')
[[ -z "$remote_tag" || "$remote_tag" == "$TARGET" ]] \
  || { echo "✗ remote tag $TAG -> $remote_tag, not $TARGET"; exit 1; }
API="https://api.github.com/repos/$REPO"
H=(-H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json")
read -r rel_id rel_draft < <(curl -fsS "$API/releases?per_page=100" "${H[@]}" \
  | python3 -c 'import json,sys; t=sys.argv[1]; r=[x for x in json.load(sys.stdin) if x["tag_name"]==t]; print(*(r and (r[0]["id"], r[0]["draft"]) or ("", "")))' "$TAG")
[[ -z "$rel_id" || "$rel_draft" == "True" ]] \
  || { echo "✗ $TAG is already PUBLISHED (id $rel_id) — not touching it"; exit 1; }
echo "✓ $TAG -> ${TARGET:0:12} (on origin/main; tag ${remote_tag:+exists}${remote_tag:-created on Publish})"

# SHA256SUMS over exactly the assets being published
( cd out && sha256sum "${ASSETS[@]#out/}" ) > out/SHA256SUMS
ASSETS+=(out/SHA256SUMS)
cat out/SHA256SUMS

# 1) create the draft, or refresh the existing draft (target, title, notes; old assets removed)
payload=$(python3 -c 'import json,sys; print(json.dumps({"tag_name":sys.argv[1],"target_commitish":sys.argv[2],"name":sys.argv[3],"body":open(sys.argv[4]).read(),"draft":True}))' "$TAG" "$TARGET" "$TITLE" "$NOTES")
if [[ -z "$rel_id" ]]; then
  resp=$(curl -fsS -X POST "$API/releases" "${H[@]}" -d "$payload")
  rel_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$resp")
  echo "✓ draft release created (id=$rel_id)"
else
  curl -fsS -X PATCH "$API/releases/$rel_id" "${H[@]}" -d "$payload" >/dev/null
  for a in $(curl -fsS "$API/releases/$rel_id/assets?per_page=100" "${H[@]}" \
             | python3 -c 'import json,sys; print(*(x["id"] for x in json.load(sys.stdin)))'); do
    curl -fsS -X DELETE "$API/releases/assets/$a" "${H[@]}"
  done
  echo "✓ existing draft refreshed (id=$rel_id), old assets removed"
fi

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
