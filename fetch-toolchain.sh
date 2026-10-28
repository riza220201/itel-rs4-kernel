#!/usr/bin/env bash
# Fetch the prebuilt Clang toolchain build.sh needs into ./toolchain/ (git-ignored,
# too big to vendor). One-time setup after cloning; skips if already present.
#
#   neutron-clang-06092026  — DEFAULT since v9 (2026-10-28): Neutron clang 24.0.0git
#                     (llvm f42c87ba), a GitHub release tarball (~78M). Proven on this
#                     device: KMI-clean, CFI type ids identical to clang-12, booted.
#                     ⚠ Any clang >= 14 needs build.sh's stack-guard pin (it has it).
#   clang-r416183b  — the AOSP toolchain MTK's stock kernel was built with (clang 12.0.5;
#                     CFI + full LTO). Releases up to v9-clang12 were built with it:
#                     CLANG_VER=clang-r416183b ./fetch-toolchain.sh, then
#                     CLANG_DIR=$PWD/toolchain/clang-r416183b ./build.sh …
#   build-tools     — AOSP-pinned host tools (make, dtc, mkbootfs, …) at
#                     toolchain/build/build-tools/path/linux-x86. OPTIONAL: build.sh
#                     falls back to your system make/coreutils if absent, so this
#                     script doesn't fetch it (the layout spans 3 AOSP repos). Copy
#                     it from an AOSP checkout if you want byte-identical host tools.
#
# AOSP clang uses a shallow + blobless + sparse checkout of prebuilts/clang so it
# pulls ONLY that version (~1.4G) instead of every clang version (many GB).
set -euo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$PROJ/toolchain"
CLANG_VER="${CLANG_VER:-neutron-clang-06092026}"
CLANG_REPO="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86"
NEUTRON_RELEASES="https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download"
say(){ echo "  [toolchain] $*"; }
die(){ echo "✗ [toolchain] $*" >&2; exit 1; }

# Known-good sha256 of <ver>/bin/clang — supply-chain verification of the fetched
# compiler (catches a tampered/corrupt download). Only the pinned versions are known; a
# custom CLANG_VER skips the hash check with a warning.
declare -A CLANG_SHA256=(
  [neutron-clang-06092026]="5ddad56ef3504ccc39da055c897ecbed28b5bfa548a8e6db9faf76c95f287438"
  [clang-r416183b]="b2ce016755bddbab76549895bca07b1dc8d14a3e315b8b3567097fef04eadae1"
)
# Neutron release tarballs (== GitHub's own asset digest), checked before extracting.
declare -A NEUTRON_TAR_SHA256=(
  [neutron-clang-06092026]="531083928c8e37f6b31e324dbfd0b5a8323f989b1c57ff2c1368b889b5b1bd30"
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
clang_version(){ "$1" --version | sed -n '1s/.*clang version \([^ ]*\).*/\1/p'; }

mkdir -p "$DEST"
if [[ -x "$DEST/$CLANG_VER/bin/clang" ]]; then
  verify_clang "$DEST/$CLANG_VER/bin/clang"
  say "$CLANG_VER already present ($(clang_version "$DEST/$CLANG_VER/bin/clang")) — nothing to do"
  exit 0
fi

TMP="$DEST/.clang-src"
rm -rf "$TMP"
if [[ "$CLANG_VER" == neutron-clang-* ]]; then
  tag="${CLANG_VER#neutron-clang-}" want="${NEUTRON_TAR_SHA256[$CLANG_VER]:-}"
  command -v zstd >/dev/null || die "zstd not installed (the Neutron tarball is .tar.zst)"
  say "fetching $CLANG_VER (Neutron-Toolchains release $tag) …"
  mkdir -p "$TMP"
  curl -fL# --retry 3 -o "$TMP/$CLANG_VER.tar.zst" "$NEUTRON_RELEASES/$tag/$CLANG_VER.tar.zst" \
    || die "download failed (network? release $tag gone?)"
  if [[ -n "$want" ]]; then
    [[ "$(sha256sum "$TMP/$CLANG_VER.tar.zst" | awk '{print $1}')" == "$want" ]] \
      || die "tarball checksum MISMATCH for $CLANG_VER — refusing to extract it"
    say "tarball checksum verified"
  else
    say "no pinned tarball checksum for $CLANG_VER — skipping"
  fi
  mkdir -p "$TMP/$CLANG_VER"
  tar -I zstd -xf "$TMP/$CLANG_VER.tar.zst" -C "$TMP/$CLANG_VER" || die "extract failed"
else
  say "fetching $CLANG_VER (shallow+sparse — only that version, not all of AOSP's clang) …"
  git clone --depth 1 --filter=blob:none --sparse "$CLANG_REPO" "$TMP" \
    || die "clone failed (network? repo moved?)"
  git -C "$TMP" sparse-checkout set "$CLANG_VER" || die "sparse-checkout of $CLANG_VER failed (version name wrong?)"
fi
[[ -x "$TMP/$CLANG_VER/bin/clang" ]] || die "$CLANG_VER/bin/clang not found after fetch"

rm -rf "$DEST/$CLANG_VER"
mv "$TMP/$CLANG_VER" "$DEST/$CLANG_VER"
rm -rf "$TMP"
verify_clang "$DEST/$CLANG_VER/bin/clang"
say "done → $DEST/$CLANG_VER  ($(clang_version "$DEST/$CLANG_VER/bin/clang"))"
say "build-tools: optional — build.sh uses system make/coreutils if toolchain/build/ is absent."
