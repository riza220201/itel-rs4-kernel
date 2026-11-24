#!/usr/bin/env bash
# package.sh — turn a gated build into the two deliverables.
#
#   ./package.sh <vanilla|ksunext>
#
#   out/<variant>/<DevSlug>-<variant>-<date>.zip       AnyKernel3, ROM-agnostic
#   out/<variant>/<DevSlug>-boot-<variant>-<date>.img  stock boot.img, rekernelled
#   (<DevSlug> is DEVICE_LABEL with non-alphanumerics dropped: InfinixHOT60Pro)
#
# ⚠ REFUSES TO RUN IF THE GATE HAS NOT PASSED for this variant. Packaging an
# ungated kernel is how an unbootable image reaches a user, and the sibling
# projects have a "self-consistent verify gate passing an unbootable image" entry
# for exactly this reason.
#
# Nothing device-specific is written here: the banner, the device names, the file
# prefix and the kernel format all resolve from device.conf and sources.lock.
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJ"
die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "== $*"; }

VARIANT="${1:-}"
[[ "$VARIANT" == "vanilla" || "$VARIANT" == "ksunext" ]] || \
  die "usage: ./package.sh <vanilla|ksunext>"

# shellcheck disable=SC1091
source "$PROJ/device.conf"
# shellcheck disable=SC1091
[[ -f "$PROJ/sources.lock" ]] && source "$PROJ/sources.lock"

KERNEL_WS="${KERNEL_WS:-$PROJ/.build/kernel}"
OUT="$PROJ/out/$VARIANT"
DATE="$(date +%Y%m%d)"
DEVSLUG="$(echo "$DEVICE_LABEL" | tr -cd '[:alnum:]')"

# ── The gate must have passed ───────────────────────────────────────────────
for f in "$OUT/kmi-check.log" "$OUT/protect-check.log" "$OUT/import-check.log"; do
  [[ -f "$f" ]] || die "no $f — run ./build.sh $VARIANT first (packaging requires a gated build)"
done
grep -q "^RESULT: CLEAN" "$OUT/kmi-check.log" || \
  die "layer 1 did not pass for $VARIANT:
$(tail -3 "$OUT/kmi-check.log")"
grep -q "^RESULT: CLEAN" "$OUT/protect-check.log" || \
  die "layer 2 did not pass for $VARIANT:
$(tail -3 "$OUT/protect-check.log")"
grep -q "^RESULT: CLEAN" "$OUT/import-check.log" || \
  die "layer 3 did not pass for $VARIANT:
$(tail -3 "$OUT/import-check.log")"
# system_dlkm logs exist only when that reference set exists (build.sh deletes stale
# ones before gating) — but when they exist, they must be CLEAN too.
for f in "$OUT/kmi-check-system.log" "$OUT/protect-check-system.log" "$OUT/import-check-system.log"; do
  [[ -f "$f" ]] || continue
  grep -q "^RESULT: CLEAN" "$f" || die "system_dlkm gate did not pass for $VARIANT ($(basename "$f")):
$(tail -3 "$f")"
done
say "gate logs confirm CLEAN for $VARIANT"

# ── Locate the built kernel ─────────────────────────────────────────────────
KSRC_VER="$(awk -F' = ' '/^VERSION/{v=$2} /^PATCHLEVEL/{p=$2} /^SUBLEVEL/{s=$2}
                         END{print v"."p"."s}' "$KERNEL_WS/common/Makefile")"
EXPECT_REL="${KSRC_VER}-$(release_tag "$VARIANT")"

case "$KERNEL_FMT" in
  lz4)  KIMG_NAME="Image.lz4" ;;
  gzip) KIMG_NAME="Image.gz"  ;;
  raw)  KIMG_NAME="Image"     ;;
  *)    die "device.conf KERNEL_FMT='$KERNEL_FMT' — expected lz4, gzip or raw" ;;
esac

# Prefer per-variant staged artifacts saved by build.sh on GATE: PASS so
# packaging vanilla after a ksunext build still finds the gated vanilla Image;
# fall back to bazel-bin with the strict release-string guard.
STAGED="$PROJ/.build/staged-$VARIANT"
BIN="$KERNEL_WS/bazel-bin/common/kernel_aarch64"
if [[ -f "$STAGED/Image" && -f "$STAGED/kernel.release" ]] \
   && [[ "$(cat "$STAGED/kernel.release" 2>/dev/null)" == "$EXPECT_REL" ]]; then
  SRC_DIR="$STAGED"
else
  SRC_DIR="$BIN"
fi

KIMG="$(find "$SRC_DIR" -maxdepth 2 -name "$KIMG_NAME" -print -quit 2>/dev/null || true)"
RAWIMG="$(find "$SRC_DIR" -maxdepth 2 -name "Image" -print -quit 2>/dev/null || true)"
[[ -n "$RAWIMG" ]] || die "no Image under $SRC_DIR — build first"
KREL="$(cat "$(find "$SRC_DIR" -maxdepth 2 -name kernel.release -print -quit)" 2>/dev/null || echo unknown)"
say "kernel.release = $KREL  (source: ${SRC_DIR#$PROJ/})"

# 🔴 bazel-bin is SHARED between variants — it holds whatever was built LAST, while
#    the gate logs come from out/<variant>/. Match the whole expected release string
#    AND the embedded Linux version banner inside the raw Image.
[[ "$KREL" == "$EXPECT_REL" ]] || die "variant/image mismatch: packaging '$VARIANT' expects
   '$EXPECT_REL' but $SRC_DIR holds '$KREL'. Re-run: ./build.sh $VARIANT"
BANNER_REL="$(LC_ALL=C grep -aom1 'Linux version [^ ]*' "$RAWIMG" 2>/dev/null | awk '{print $3}' || true)"
[[ "$BANNER_REL" == "$EXPECT_REL" ]] || die "Image banner release is '$BANNER_REL', expected '$EXPECT_REL'"
say "variant check ok — the image in ${SRC_DIR#$PROJ/} is the $VARIANT build"

# ── Read dynamic compiler & KSU/SusFS metadata (never hardcoded) ────────────
COMPILER="$(LC_ALL=C grep -aom1 'Linux version [[:print:]]*' "$RAWIMG" 2>/dev/null \
            | sed -n 's/.*(\([^(]*\)\(([^)]*) \)\{0,1\}clang version \([^ )]*\).*/\1clang \3/p' \
            | head -1 || true)"
[[ -n "$COMPILER" ]] || COMPILER="unknown"

KSUNVER="${WILDKSU_VER_EXPECT:-unknown}"
KSUN_TAG="$(git -C "$PROJ/.build/wildksu" describe --tags --abbrev=0 --match 'v[0-9]*' \
            --exclude '*-legacy' "${WILDKSU_VERBASE:-HEAD}" 2>/dev/null || true)"
[[ -n "$KSUN_TAG" ]] || KSUN_TAG="v?"
ksun_uapi() {
  git -C "$PROJ/.build/wildksu" show "$1:uapi/supercall.h" 2>/dev/null \
    | sed -n 's/.*KERNEL_SU_UAPI_VERSION[[:space:]]*[=[:space:]][[:space:]]*\([0-9]*\).*/\1/p' \
    | head -1 || true
}
KSUN_UAPI="$(ksun_uapi "${WILDKSU_VERBASE:-HEAD}")"
if [[ -n "$KSUN_UAPI" && "$KSUN_UAPI" == "$(ksun_uapi "$KSUN_TAG")" ]]; then
  KSUN_MGR="$KSUN_TAG manager"
else
  KSUN_DESC="$(git -C "$PROJ/.build/wildksu" describe --tags --match 'v[0-9]*' \
               --exclude '*-legacy' "${WILDKSU_VERBASE:-HEAD}" 2>/dev/null || echo '?')"
  KSUN_MGR="CI manager $KSUN_DESC, uapi ${KSUN_UAPI:-?}"
fi

SUSFS_VER="$(sed -n 's/.*#define SUSFS_VERSION[[:space:]]*"\(v[0-9.]*\)".*/\1/p' \
              "$PROJ/.build/susfs-612/kernel_patches/include/linux/susfs.h" 2>/dev/null \
             | head -1 || true)"
[[ -n "$SUSFS_VER" ]] || SUSFS_VER="unknown"

case "$VARIANT" in
  vanilla)
    LABEL="Vanilla"
    ROOTLINE='ui_print "   [+] root    : none (vanilla)";'
    ;;
  ksunext)
    LABEL="KernelSU-Next+SusFS"
    ROOTLINE="ui_print \"   [+] root    : KernelSU-Next $KSUN_TAG ($KSUNVER) + SusFS $SUSFS_VER ($KSUN_MGR)\";"
    ;;
esac

# Same shape as the itel RS4's installer string.
KSTRING="${DEVICE_LABEL} ${BRAND_FULL} (${VARIANT}) • ${KREL} • ${DATE}"

mkdir -p "$OUT"

# ── 1. AnyKernel3 zip (the ROM-agnostic deliverable) ────────────────────────
# It keeps whatever ramdisk is on the device and swaps only the kernel, so it
# works on stock and on any custom ROM.
AK="$PROJ/.build/ak3-$VARIANT"
rm -rf "$AK"; cp -r "$PROJ/anykernel" "$AK"; rm -rf "$AK/.git"
rm -f "$AK"/Image* "$AK"/zImage* 2>/dev/null || true

# Ship the RAW Image. On the itel RS4, shipping Image.gz and forcing
# IS_SLOT_DEVICE=1 made OrangeFox abort with "unable to determine slot"; the
# proven reference used the raw Image and IS_SLOT_DEVICE=auto.
cp "$RAWIMG" "$AK/Image"

# device.nameN lines, only for names that exist. Empty DEVICE_NAMES +
# do.devicecheck=0 means the zip installs anywhere, which is what we want until
# someone reads `getprop ro.product.device` off the phone.
NAMELINES=""; i=1
for n in $DEVICE_NAMES; do NAMELINES+="device.name${i}=${n}"$'\n'; i=$((i+1)); done
DEVCHECK=0; [[ -n "$DEVICE_NAMES" ]] && DEVCHECK=1

# ⚠ CRITICAL: tools/ak3-core.sh reads UPPERCASE variable names:
#   BLOCK, IS_SLOT_DEVICE, RAMDISK_COMPRESSION, PATCH_VBMETA_FLAG
# Using lowercase (block=..., is_slot_device=...) leaves $BLOCK and
# $IS_SLOT_DEVICE empty in setup_ak(), which immediately aborts with
# "Unable to determine  partition. Aborting...".
cat > "$AK/anykernel.sh" <<AKEOF
### AnyKernel3 Ramdisk Mod Script
## $DEVICE_LABEL ($DEVICE_SOC) — $VARIANT

properties() { '
kernel.string=${KSTRING}
do.devicecheck=${DEVCHECK}
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
${NAMELINES}supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

# shell variables
BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

ui_print " ";
ui_print "   ══════════════════════════════════════════════";
ui_print "     ${DEVICE_LABEL} — ${BRAND_FULL}";
ui_print "     ${DEVICE_SOC}";
ui_print "     Linux ${KREL} · KMI-clean GKI";
ui_print "   ══════════════════════════════════════════════";
ui_print " ";
ui_print "     variant : ${LABEL}";
ui_print "     version : ${KREL}";
ui_print "     compiler: ${COMPILER}";
ui_print " ";
ui_print "   ────────────────────────────────────────────";
ui_print "   [+] vendor modules load native (module_layout";
ui_print "       ${MODULE_LAYOUT} — 424 vendor + 81 GKI CLEAN)";
ui_print "   [+] sched   : BORE 7.0.0 · Reflex 0.4.0 gov";
ui_print "   [+] network : BBR default · fq/cake · TCP suite";
ui_print "   [+] storage : ADIOS 3.3.0 · BFQ";
ui_print "   [+] memory  : Kcompressd 0.5 · le9uo 1.14 · MGLRU";
${ROOTLINE}
ui_print "   ────────────────────────────────────────────";
ui_print " ";

# 6.12 sanity guard (X6886 pre-A16 firmware runs 5.10.237; only A16 runs 6.12.38).
kver=\$(cat /proc/version | awk '{print \$3}' | cut -d- -f1)
case "\$kver" in
  6.12.*) ui_print " -> ROM is on \$kver (6.12 base OK) — installing ${KREL}" ;;
  *)      abort " -> not a 6.12 ROM (\$kver) — wrong device or pre-A16 firmware?" ;;
esac

# boot install: split_boot unpacks boot.img into \$SPLITIMG first; only unpack
# and repack the ramdisk if boot.img actually carries one (on Android 16 6.12
# GKI, boot.img is header v4 kernel-only with RAMDISK_SZ=0 and ramdisk in
# vendor_boot, where unpack_ramdisk would abort with "No ramdisk found").
split_boot;
if [ -f "\$SPLITIMG/ramdisk.cpio" ] || [ -d "\$SPLITIMG/vendor_ramdisk" ]; then
  unpack_ramdisk;
  write_boot;
else
  flash_boot;
fi
AKEOF

# ── Verify the generated AnyKernel3 installer end-to-end before zipping ─────
# A broken anykernel.sh (e.g. lowercase block=/is_slot_device=) used to ship
# silently because nothing executed it against stock boot.img at package time.
AK_TEST="$(mktemp -d)"
trap 'rm -rf "$AK_TEST"' EXIT
cp -r "$AK" "$AK_TEST/ak"
cp "$STOCK_BOOT_IMG" "$AK_TEST/boot_a"
# In the throwaway test copy ($AK_TEST), replace the ARM32 recovery binaries
# with host x86_64 busybox and magiskboot so we don't trigger qemu-arm binfmt
# (which can futex-deadlock when fork()ing with inherited fds).
ln -sf "$(command -v busybox)" "$AK_TEST/ak/tools/busybox"
ln -sf "$(command -v magiskboot)" "$AK_TEST/ak/tools/magiskboot"
# Rewrite BLOCK to the relative path under /dev (..$AK_TEST/boot_a), bound dd
# to 64 MiB (since boot_a is a regular file here, not a block device), and stub
# /proc/version to 6.12.38 so the 6.12 sanity guard passes on the build host.
sed -i \
  -e "s|^BLOCK=boot;|BLOCK=..${AK_TEST}/boot_a;\nCUSTOMDD=\"bs=1048576 count=64\";|" \
  -e 's|cat /proc/version|echo "Linux version 6.12.38-android16-5-gb575a0b6e647-ab14355190-4k"|' \
  "$AK_TEST/ak/anykernel.sh"
(
  cd "$AK_TEST/ak"
  PATH="$AK_TEST/ak/tools:$PATH" busybox ash anykernel.sh 1 >/dev/null 2>&1
) || die "AnyKernel3 installer self-test failed on stock boot.img"
(
  mkdir -p "$AK_TEST/verify"
  cd "$AK_TEST/verify"
  cp "$AK_TEST/boot_a" flashed.img
  magiskboot unpack flashed.img >/dev/null 2>&1 || die "AnyKernel3 verify unpack failed"
  cmp -s kernel "$RAWIMG" || die "AnyKernel3 flashed boot.img kernel does NOT match our Image"
)
rm -rf "$AK_TEST"
trap - EXIT
say "AnyKernel3 self-test: PASS (repacked boot_a embeds byte-identical Image)"

ZIP="$OUT/${DEVSLUG}-${VARIANT}-${DATE}.zip"
rm -f "$ZIP"
( cd "$AK" && zip -r9 "$ZIP" . -x '.git*' 'README.md' '.github*' >/dev/null )
say "AnyKernel3 zip: $ZIP"

# ── 2. Prebuilt boot.img (stock firmware only) ──────────────────────────────
# ⚠ This carries the STOCK boot image's own structure.
BOOTIMG="$OUT/${DEVSLUG}-boot-${VARIANT}-${DATE}.img"
if [[ -n "$KIMG" ]]; then
  W="$PROJ/.build/repack-$VARIANT"; rm -rf "$W"; mkdir -p "$W"
  cp "$STOCK_BOOT_IMG" "$W/boot.img"
  (
    cd "$W"
    magiskboot unpack boot.img >/dev/null 2>&1 || die "magiskboot unpack failed"
    # magiskboot decompresses the kernel on unpack and re-compresses to the stock
    # format (lz4_legacy) on repack, so hand it the RAW Image as `kernel`.
    cp "$RAWIMG" kernel
    magiskboot repack boot.img "$BOOTIMG" >/dev/null 2>&1 || die "magiskboot repack failed"
  )
  # Verify the repacked boot.img embeds our kernel byte-for-byte (same check as itel RS4).
  (
    cd "$W"
    rm -f kernel ramdisk.cpio dtb kernel_dtb 2>/dev/null || true
    cp "$BOOTIMG" check.img
    magiskboot unpack check.img >/dev/null 2>&1 || die "verify unpack failed"
    cmp -s kernel "$RAWIMG" || die "boot.img kernel does NOT match our Image — repack wrong"
  )
  say "boot.img: $BOOTIMG  (verified byte-identical Image)"
else
  echo "   (no $KIMG_NAME built; skipping boot.img repack)"
fi

echo
say "SHA256"
( cd "$OUT" && sha256sum ./*.zip ./*.img 2>/dev/null || true )
