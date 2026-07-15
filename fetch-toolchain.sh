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

# Known-good sha256 of <ver>/bin/clang — supply-chain verification of the fetched
# compiler (catches a tampered/corrupt download). Only the pinned default is known; a
# custom CLANG_VER skips the hash check with a warning.
declare -A CLANG_SHA256=(
  [clang-r416183b]="b2ce016755bddbab76549895bca07b1dc8d14a3e315b8b3567097fef04eadae1"
)
verify_clang(){
  local bin="$1" want="${CLANG_SHA256[$CLANG_VER]:-}"
  [[ -x "$bin" ]] || die "clang binary missing at $bin"
  [[ -n "$want" ]] || { say "no pinned checksum for $CLANG_VER — skipping hash verify"; return 0; }
  local got; got="$(sha256sum "$bin" | awk '{print $1}')"
  [[ "$got" == "$want" ]] || die "clang checksum MISMATCH for $CLANG_VER:
    expected $want
    got      $got
  (tampered/corrupt download, or wrong version) — refusing to use it."
  say "clang checksum verified ($CLANG_VER)"
}

mkdir -p "$DEST"
if [[ -x "$DEST/$CLANG_VER/bin/clang" ]]; then
  verify_clang "$DEST/$CLANG_VER/bin/clang"
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
verify_clang "$DEST/$CLANG_VER/bin/clang"
say "done → $DEST/$CLANG_VER  ($("$DEST/$CLANG_VER/bin/clang" --version | awk 'NR==1{print $NF}'))"
say "build-tools: optional — build.sh uses system make/coreutils if toolchain/build/ is absent."
