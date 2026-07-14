#!/usr/bin/env bash
# Fetch the prebuilt Clang toolchain build.sh needs into ./toolchain/ (git-ignored,
# 1.4G — too big to vendor). One-time setup after cloning; skips if already present.
#
#   clang-r416183b  — the exact AOSP toolchain that reproduces this device's KMI
#                     (clang 12.0.5 / r416183b; CFI + full LTO). Essential; fetched here.
#   build-tools     — AOSP-pinned host tools (make, dtc, mkbootfs, …) at
#                     toolchain/build/build-tools/path/linux-x86. OPTIONAL: build.sh
#                     falls back to your system make/coreutils if absent, so this
#                     script doesn't fetch it (the layout spans 3 AOSP repos). Copy
#                     it from an AOSP checkout if you want byte-identical host tools.
#
# Uses a shallow + blobless + sparse checkout of AOSP's prebuilts/clang repo so it
# pulls ONLY clang-r416183b (~1.4G) instead of every clang version (many GB).
set -euo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$PROJ/toolchain"
CLANG_VER="${CLANG_VER:-clang-r416183b}"
CLANG_REPO="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86"
say(){ echo "  [toolchain] $*"; }
die(){ echo "✗ [toolchain] $*" >&2; exit 1; }

mkdir -p "$DEST"
if [[ -x "$DEST/$CLANG_VER/bin/clang" ]]; then
  say "$CLANG_VER already present ($("$DEST/$CLANG_VER/bin/clang" --version | awk 'NR==1{print $NF}')) — nothing to do"
  exit 0
fi

say "fetching $CLANG_VER (shallow+sparse — only that version, not all of AOSP's clang) …"
TMP="$DEST/.clang-src"
rm -rf "$TMP"
git clone --depth 1 --filter=blob:none --sparse "$CLANG_REPO" "$TMP" \
  || die "clone failed (network? repo moved?)"
git -C "$TMP" sparse-checkout set "$CLANG_VER" || die "sparse-checkout of $CLANG_VER failed (version name wrong?)"
[[ -x "$TMP/$CLANG_VER/bin/clang" ]] || die "$CLANG_VER/bin/clang not found after checkout"

rm -rf "$DEST/$CLANG_VER"
mv "$TMP/$CLANG_VER" "$DEST/$CLANG_VER"
rm -rf "$TMP"
say "done → $DEST/$CLANG_VER  ($("$DEST/$CLANG_VER/bin/clang" --version | awk 'NR==1{print $NF}'))"
say "build-tools: optional — build.sh uses system make/coreutils if toolchain/build/ is absent."
