#!/usr/bin/env bash
# Package a built variant into: (1) a stock boot.img with our kernel swapped in
# (gzip, matching stock KERNEL_FMT) for direct antumbra DA flash, and (2) a
# ROM-agnostic AnyKernel3 zip. Called by build.sh --pack, or standalone with
# VARIANT=<v> ./package.sh
set -euo pipefail
PROJ="${PROJ:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
VARIANT="${VARIANT:?set VARIANT=vanilla|ksu|kowsu}"
BOOT_IMG="${BOOT_IMG:-/home/riza/droidian-s666ln/boot.img}"
O="$PROJ/out/$VARIANT"
die() { echo "✗ $*" >&2; exit 1; }

[[ -f "$O/Image.gz" ]] || die "no Image.gz in $O — build the '$VARIANT' variant first"
command -v magiskboot >/dev/null || die "magiskboot not on PATH"
command -v zip >/dev/null || die "zip not installed"

KREL="$(cat "$PROJ/.build/out-$VARIANT/include/config/kernel.release" 2>/dev/null || echo '5.10.258')"
DATE="$(date +%Y%m%d)"
case "$VARIANT" in
  vanilla) LABEL="Vanilla"
           ROOTLINE='ui_print "   [+] root    : none (vanilla)"' ;;
  ksu)     LABEL="KernelSU+SusFS"
           ROOTLINE='ui_print "   [+] root    : KernelSU v3.2.5 + SusFS v2.2.0"' ;;
  kowsu)   LABEL="KoWSU"
           ROOTLINE='ui_print "   [+] root    : KoWSU v3.2.5 (manager v3.2.5+)"' ;;
  *)       die "unknown VARIANT=$VARIANT (vanilla|ksu|kowsu)" ;;
esac
KSTRING="Itel RS4 $LABEL Kernel • $KREL • $DATE"
# Variant-unique boot.img name so release assets don't collide (GitHub needs
# unique filenames); the AnyKernel3 zip is already variant-named.
BOOTIMG="$O/ItelRS4-boot-$VARIANT-$DATE.img"

echo "▶ Packaging variant=$VARIANT  ($KREL)"

# ── 1) Stock boot.img with our kernel (gzip) ───────────────────────────────────
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cp "$BOOT_IMG" "$W/boot.img"; cp "$O/Image.gz" "$W/Image.gz"
( cd "$W"
  magiskboot unpack boot.img >/dev/null 2>&1 || die "magiskboot unpack failed"
  cp Image.gz kernel                                   # stock KERNEL_FMT = gzip
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
cat > "$AKW/anykernel.sh" <<AKEOF
### AnyKernel3 — Itel RS4 (S666LN / MT6789)
properties() { '
kernel.string=$KSTRING
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=S666LN
device.name2=itel-S666LN
device.name3=RS4
device.name4=Itel-S666LN
device.name5=
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
ui_print "   ╔══════════════════════════════════════════╗";
ui_print "   ║                                          ║";
ui_print "   ║       I T E L   R S 4   K E R N E L       ║";
ui_print "   ║      MediaTek MT6789 · Helio G99          ║";
ui_print "   ║      Linux 5.10 · KMI-clean GKI           ║";
ui_print "   ║                                          ║";
ui_print "   ╚══════════════════════════════════════════╝";
ui_print " ";
ui_print "     variant : $LABEL";
ui_print "     version : $KREL";
ui_print " ";
ui_print "   ────────────────────────────────────────────";
ui_print "   [+] vendor modules load native (module_layout";
ui_print "       0x7c24b32d — every ROM's HALs intact)";
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

ZIP="$O/ItelRS4-Kernel-$VARIANT-$DATE.zip"
rm -f "$ZIP"
( cd "$AKW" && zip -r9 "$ZIP" . -x '.git*' 'README.md' '.github*' >/dev/null ) || die "zip failed"
echo "  ✓ $ZIP  (sha $(sha256sum "$ZIP" | cut -c1-12)…)"

( cd "$O" && sha256sum "$(basename "$BOOTIMG")" "$(basename "$ZIP")" >> SHA256SUMS )
echo "✓ Packaging done → $O/"
