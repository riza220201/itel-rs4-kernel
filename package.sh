#!/usr/bin/env bash
# Package a built variant into: (1) a stock boot.img with our kernel swapped in
# (matching the stock kernel format — KERNEL_FMT) for direct DA flash, and (2) a
# ROM-agnostic AnyKernel3 zip. Called by build.sh --pack, or standalone with
# VARIANT=<v> ./package.sh
set -euo pipefail
PROJ="${PROJ:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
VARIANT="${VARIANT:?set VARIANT=vanilla|kowsu|ksunext}"
# Pull the pinned KSU version from the same sources.lock the build uses, so the
# installer banner can't disagree with the version the kernel actually reports.
LOCKFILE="${LOCKFILE:-$PROJ/sources.lock}"
# shellcheck source=/dev/null
[[ -f "$LOCKFILE" ]] && source "$LOCKFILE"
KSUNVER="${WILDKSU_VER_EXPECT:-33219}"
KOWSUVER="${KOWSU_VER_EXPECT:-32579}"

# ── Device identity: env (from build.sh) wins; else device.conf; else defaults ──
# Sourcing device.conf is only for standalone `VARIANT=x ./package.sh` runs (build.sh
# already passes these through), so guard on a key var to avoid clobbering that env.
DEVICE_CONF="${DEVICE_CONF:-$PROJ/device.conf}"
if [[ -z "${DEVICE_LABEL:-}${MODULE_LAYOUT:-}" && -f "$DEVICE_CONF" ]]; then
  # shellcheck source=/dev/null
  source "$DEVICE_CONF"
fi
DEVICE_LABEL="${DEVICE_LABEL:-Itel RS4}"
DEVICE_SOC="${DEVICE_SOC:-MediaTek MT6789 · Helio G99}"
DEVICE_NAMES="${DEVICE_NAMES:-S666LN itel-S666LN RS4 Itel-S666LN}"
KERNEL_FMT="${KERNEL_FMT:-gzip}"
MODULE_LAYOUT="${MODULE_LAYOUT:-0x7c24b32d}"
BRAND="${BRAND:-Riza}"
DEVSLUG="$(echo "$DEVICE_LABEL" | tr -cd '[:alnum:]')"   # release-file prefix (e.g. ItelRS4)

BOOT_IMG="${BOOT_IMG:-$PROJ/boot.img}"      # stock boot.img (local, git-ignored)
O="$PROJ/out/$VARIANT"
die() { echo "✗ $*" >&2; exit 1; }

# Stock boot.img kernel format → which built artifact we swap in. magiskboot detects
# the format of the file we hand it and repacks to match the stock kernel's format.
case "$KERNEL_FMT" in
  gzip) KIMG="Image.gz" ;;
  lz4)  KIMG="Image.lz4" ;;
  raw)  KIMG="Image" ;;
  *)    die "unknown KERNEL_FMT=$KERNEL_FMT (expected gzip|lz4|raw)" ;;
esac

[[ -f "$O/$KIMG" ]] || die "no $KIMG in $O — build the '$VARIANT' variant first"
[[ -f "$BOOT_IMG" ]] || die "stock boot.img not found at $BOOT_IMG — drop your device's stock boot.img there (or set BOOT_IMG=...)"
command -v magiskboot >/dev/null || die "magiskboot not on PATH"
command -v zip >/dev/null || die "zip not installed"

KOUT="${KOUT:-$PROJ/.build/out-$VARIANT}"   # build out-dir (matches build.sh's KOUT override)
# kernel.release is written by the build and should always be here; if it's somehow
# missing, derive VERSION.PATCHLEVEL.SUBLEVEL from the source Makefile rather than a
# stale hardcoded number.
KREL="$(cat "$KOUT/include/config/kernel.release" 2>/dev/null || true)"
if [[ -z "$KREL" ]]; then
  KREL="$(awk '/^VERSION/{v=$3}/^PATCHLEVEL/{p=$3}/^SUBLEVEL/{s=$3}END{print v"."p"."s}' "${KERNEL_SRC:-$PROJ/common}/Makefile" 2>/dev/null || echo unknown)"
fi
DATE="$(date +%Y%m%d)"
case "$VARIANT" in
  vanilla) LABEL="Vanilla"
           ROOTLINE='ui_print "   [+] root    : none (vanilla)"' ;;
  kowsu)   LABEL="KoWSU"
           ROOTLINE="ui_print \"   [+] root    : KoWSU $KOWSUVER (install the MATCHING KOWX712 manager)\"" ;;
  ksunext) LABEL="KernelSU-Next+SusFS"
           ROOTLINE="ui_print \"   [+] root    : KernelSU-Next v3.3.0 ($KSUNVER) + SusFS v2.2.0 (v3.3.0 manager)\"" ;;
  *)       die "unknown VARIANT=$VARIANT (vanilla|kowsu|ksunext)" ;;
esac
KSTRING="$DEVICE_LABEL $LABEL Kernel • $KREL • $DATE"
# Variant-unique boot.img name so release assets don't collide (GitHub needs
# unique filenames); the AnyKernel3 zip is already variant-named.
BOOTIMG="$O/${DEVSLUG}-boot-$VARIANT-$DATE.img"

echo "▶ Packaging variant=$VARIANT  ($KREL)"

# ── 1) Stock boot.img with our kernel (KERNEL_FMT=$KERNEL_FMT) ──────────────────
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cp "$BOOT_IMG" "$W/boot.img"; cp "$O/$KIMG" "$W/$KIMG"
( cd "$W"
  magiskboot unpack boot.img >/dev/null 2>&1 || die "magiskboot unpack failed"
  cp "$KIMG" kernel                                    # swap in our kernel (stock fmt: $KERNEL_FMT)
  magiskboot repack boot.img "$BOOTIMG" >/dev/null 2>&1 || die "magiskboot repack failed"
)
# verify: the boot.img we just built embeds OUR kernel. magiskboot DECOMPRESSES
# the kernel on unpack, so the extracted `kernel` file is the raw Image → cmp it.
( cd "$W"
  rm -f kernel ramdisk.cpio dtb kernel_dtb 2>/dev/null || true
  cp "$BOOTIMG" check.img
  magiskboot unpack check.img >/dev/null 2>&1 || die "verify unpack failed"
  cmp -s kernel "$O/Image" && echo "  ✓ boot.img embeds our kernel (byte-identical)" \
    || die "boot.img kernel does NOT match our Image — repack wrong"
)
echo "  ✓ $BOOTIMG  (sha $(sha256sum "$BOOTIMG" | cut -c1-12)…)"

# ── 2) AnyKernel3 zip (ROM-agnostic) ───────────────────────────────────────────
AKW="$PROJ/.build/ak3-$VARIANT"
rm -rf "$AKW"; cp -r "$PROJ/anykernel" "$AKW"; rm -rf "$AKW/.git"
# device-specific anykernel.sh: device check OFF (works on stock + any ROM),
# A/B slot, swap kernel only (preserve the ROM's ramdisk/dtb/cmdline).
# anykernel.sh mirrors the proven GrayRavens-Zenithed layout for THIS device:
# IS_SLOT_DEVICE=auto (forcing =1 made OrangeFox abort "unable to determine slot"),
# and the init_boot conditional picks the right install path (this device is
# Android 12 → ramdisk in boot → dump/write_boot).
# AnyKernel3 device.name1..N from DEVICE_NAMES (space-separated)
DEVNAMES_BLOCK=""; _i=1
for _n in $DEVICE_NAMES; do DEVNAMES_BLOCK+="device.name${_i}=${_n}"$'\n'; _i=$((_i+1)); done
DEVNAMES_BLOCK="${DEVNAMES_BLOCK%$'\n'}"
cat > "$AKW/anykernel.sh" <<AKEOF
### AnyKernel3 — $DEVICE_LABEL
properties() { '
kernel.string=$KSTRING
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
${DEVNAMES_BLOCK}
supported.versions=
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
ui_print "     $DEVICE_LABEL — custom kernel";
ui_print "     $DEVICE_SOC";
ui_print "     Linux $KREL · KMI-clean GKI";
ui_print "   ══════════════════════════════════════════════";
ui_print " ";
ui_print "     variant : $LABEL";
ui_print "     version : $KREL";
ui_print " ";
ui_print "   ────────────────────────────────────────────";
ui_print "   [+] vendor modules load native (module_layout";
ui_print "       $MODULE_LAYOUT — every ROM's HALs intact)";
ui_print "   [+] sched   : BORE default-on (sysctl kernel.sched_bore)";
ui_print "   [+] network : BBR · fq/cake · WireGuard · TTL/HL";
ui_print "   [+] storage : BFQ/Kyber · all governors";
ui_print "   [+] memory  : zstd/lz4/lzo-rle  (zram: load as module)";
$ROOTLINE;
ui_print "   ────────────────────────────────────────────";
ui_print " ";

# 5.10 sanity guard
kver=\$(cat /proc/version | awk '{print \$3}' | cut -d- -f1)
case "\$kver" in 5.10.*) ui_print " -> kernel base \$kver OK" ;; *) abort " -> not a 5.10 ROM (\$kver) — wrong device?" ;; esac

# boot install (proven GrayRavens logic for this device)
if [ -L "/dev/block/bootdevice/by-name/init_boot_a" ] || [ -L "/dev/block/by-name/init_boot_a" ]; then
  split_boot; flash_boot;   # init_boot-ramdisk devices (boot = kernel only)
else
  dump_boot; write_boot;    # Android 12: ramdisk in boot, swap kernel + repack
fi
AKEOF
# ship the raw Image (matches the reference kernel; AK3 repacks to the ROM's format)
rm -f "$AKW"/Image "$AKW"/Image.* 2>/dev/null || true
cp "$O/Image" "$AKW/Image"

ZIP="$O/${DEVSLUG}-Kernel-$VARIANT-$DATE.zip"
rm -f "$ZIP"
( cd "$AKW" && zip -r9 "$ZIP" . -x '.git*' 'README.md' '.github*' >/dev/null ) || die "zip failed"
echo "  ✓ $ZIP  (sha $(sha256sum "$ZIP" | cut -c1-12)…)"

# Trim the output dir to ONLY the release flashables — the just-built boot .img +
# AnyKernel3 .zip. Everything else (Image/Image.gz/Image.lz4, kernel.config,
# vmlinux.symvers, any older-dated builds, stale SHA256SUMS) is a build byproduct
# and is removed here so out/<variant>/ is upload-ready with no manual cleanup.
# The raw build products still live in .build/out-$VARIANT if you need them.
find "$O" -maxdepth 1 -type f \
     ! -name "$(basename "$BOOTIMG")" ! -name "$(basename "$ZIP")" -delete
echo "✓ Packaging done → $O/  (only $(basename "$BOOTIMG") + $(basename "$ZIP"))"
