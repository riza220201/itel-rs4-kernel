#!/usr/bin/env bash
# Extract the stock kernel .config from the device's stock boot.img → the base config
# the KMI build composes on top of. Run it ONCE after dropping your device's stock
# boot.img at $PROJ/boot.img (or set BOOT_IMG=…); build.sh then uses the local
# .build/ikconfig/stock.config and needs NO external config source.
#
# WHY this config is load-bearing (not just any defconfig): it carries the device's
# real production flags — CFI_CLANG + LTO_CLANG_FULL + MODVERSIONS and the
# struct-affecting options — that reproduce the device KMI (module_layout). Building
# on gki_defconfig instead gives a different module_layout and boots nothing. The
# build refuses a config without CFI_CLANG, and this script sanity-checks it here too.
#
# Mechanism: the stock kernel is built with CONFIG_IKCONFIG(_PROC), which embeds its
# own .config (gzip, wrapped in IKCFG_ST/IKCFG_ED markers). scripts/extract-ikconfig
# scans the image for that blob and inflates it — works straight on the boot.img
# regardless of the kernel's own compression (gzip/lz4/raw).
set -euo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_CONF="${DEVICE_CONF:-$PROJ/device.conf}"
# shellcheck source=/dev/null
[[ -f "$DEVICE_CONF" ]] && source "$DEVICE_CONF"        # may set BOOT_IMG / STOCK_CONFIG / KERNEL_SRC
BOOT_IMG="${BOOT_IMG:-$PROJ/boot.img}"
KERNEL_SRC="${KERNEL_SRC:-$PROJ/common}"
OUT="${STOCK_CONFIG:-$PROJ/.build/ikconfig/stock.config}"
say(){ echo "  [extract-config] $*"; }
die(){ echo "✗ [extract-config] $*" >&2; exit 1; }

EIK="$KERNEL_SRC/scripts/extract-ikconfig"
[[ -x "$EIK" ]] || die "extract-ikconfig not found at $EIK (need the kernel source — init the 'common' submodule)"
[[ -f "$BOOT_IMG" ]] || die "stock boot.img not found at $BOOT_IMG — drop your device's stock boot.img there (or set BOOT_IMG=…)"

mkdir -p "$(dirname "$OUT")"
say "extract-ikconfig from $(basename "$BOOT_IMG")"
if ! "$EIK" "$BOOT_IMG" > "$OUT" 2>/dev/null || [[ ! -s "$OUT" ]]; then
  # Fallback: some images only yield the config after unpacking. Try the raw kernel.
  say "direct extract came up empty — unpacking boot.img with magiskboot and retrying"
  command -v magiskboot >/dev/null || die "direct extract failed and magiskboot not on PATH for the fallback (add anykernel/tools to PATH, or extract manually)"
  W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
  cp "$BOOT_IMG" "$W/boot.img"
  ( cd "$W" && magiskboot unpack boot.img >/dev/null 2>&1 ) || die "magiskboot unpack failed"
  [[ -f "$W/kernel" ]] || die "no kernel found inside boot.img after unpack"
  "$EIK" "$W/kernel" > "$OUT" 2>/dev/null || die "extract-ikconfig failed on the unpacked kernel too — is the stock kernel built with CONFIG_IKCONFIG_PROC?"
fi

[[ -s "$OUT" ]] || die "extracted config is empty — stock kernel likely lacks CONFIG_IKCONFIG_PROC (can't recover its config this way)"
n=$(grep -c '^CONFIG_' "$OUT")
grep -q '^CONFIG_CFI_CLANG=y' "$OUT" \
  || die "extracted config lacks CONFIG_CFI_CLANG=y — wrong image, or a non-GKI/non-CFI kernel; building on it would break the KMI"
say "OK: $n CONFIG_ options, CFI_CLANG=y present → $OUT"
say "build.sh will use this as STOCK_CONFIG (its default is exactly this path)."
