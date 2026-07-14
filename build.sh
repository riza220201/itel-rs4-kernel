#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# Itel RS4 (S666LN / MT6789) custom kernel — build orchestrator
#
#   ./build.sh <variant>            build + KMI-gate + publish Image{,.gz,.lz4}
#   ./build.sh <variant> --pack     also build AnyKernel3 zip + stock boot.img
#
#   variant = vanilla | kowsu | ksunext   (all carry BORE + perf + network)
#     vanilla  : stock config + performance + network + BORE (no root)
#     kowsu    : vanilla + KoWSU (KOWX712/KernelSU) standalone, own hiding, no SusFS
#     ksunext  : vanilla + KernelSU-Next v3.3.0 "Wild" dev-susfs + SusFS v2.2.0
#                (the root variant — replaced the old official-KernelSU `ksu` one)
#
# RECOVERY GOTCHA (learned the hard way): CONFIG_ZRAM MUST NOT be built in on this
# device — it bricks OrangeFox (ofox runs from /tmp tmpfs, recovery shares the
# `boot` kernel since there's no recovery partition, and built-in ZRAM's early mm
# collides with that). So ZRAM stays OUT of the kernel (load it as a KSU-Next
# module at normal boot). BORE was wrongly blamed for this and is fine — it's on.
# Root note: KSU-Next + SusFS and SukiSU-Ultra + SusFS lack a clean SusFS pairing
# on this restructured-KSU 5.10 tree — official KernelSU + SusFS stays the root.
#
# Design rule #0: the kernel MUST reproduce the device's KMI (module_layout +
# 0 CRC mismatches vs the stock vendor_dlkm modules) or it won't boot ANY ROM on
# this device (stock or custom — they all reuse the vendor partition). The target
# CRC lives in device.conf; the build dies loud if it ever regresses.
#   Proven 2026-07-14: the KMI is CONFIG-borne, not source-borne — pristine Google
#   GKI android12-5.10-lts (the `common` submodule) + MTK's stock config reproduces
#   the RS4 KMI (0x7c24b32d, 198/198) and is MORE stable on-device than MillenniumOSS,
#   so this tool now builds from Google's upstream source by default.
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Device config (KMI target + optional paths) — makes the tool device-agnostic ─
# device.conf carries the one make-or-break device value: MODULE_LAYOUT (the KMI
# CRC the vendor blobs demand). It is sourced here so it can also set paths;
# validated below (build refuses if MODULE_LAYOUT is empty/garbage). Env vars set
# on the command line still win over the file.
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_CONF="${DEVICE_CONF:-$PROJ/device.conf}"
_ENV_MODULE_LAYOUT="${MODULE_LAYOUT-}"
# shellcheck source=/dev/null
[[ -f "$DEVICE_CONF" ]] && source "$DEVICE_CONF"            # sets MODULE_LAYOUT (+ optional paths)
[[ -n "$_ENV_MODULE_LAYOUT" ]] && MODULE_LAYOUT="$_ENV_MODULE_LAYOUT"
MODULE_LAYOUT="${MODULE_LAYOUT:-}"                          # validated in preflight

# ── Paths (device.conf > env > defaults) ───────────────────────────────────────
DROIDIAN="${DROIDIAN:-/home/riza/droidian-s666ln}"          # device assets (config/toolchain/vendor)
KERNEL_SRC="${KERNEL_SRC:-$PROJ/common}"                    # Google GKI android12-5.10-lts (submodule)
STOCK_CONFIG="${STOCK_CONFIG:-$DROIDIAN/.build/ikconfig/stock.config}"
BOOT_IMG="${BOOT_IMG:-$PROJ/boot.img}"                      # stock boot.img (local, git-ignored)
VENDOR_KO_DIR="${VENDOR_KO_DIR:-$DROIDIAN/device_itel_S666LN-kernel/vendor_dlkm}"
CLANG_DIR="${CLANG_DIR:-$PROJ/toolchain/clang-r416183b}"    # local (git-ignored; fetch-toolchain.sh)
BUILD_TOOLS="${BUILD_TOOLS:-$PROJ/toolchain/build/build-tools/path/linux-x86}"  # optional (host tools if absent)

NPROC="$(nproc)"

# ── Small helpers ──────────────────────────────────────────────────────────────
c() { printf '\033[%sm' "$1"; }
hdr()  { echo; echo "$(c '1;36')════ $* ════$(c 0)"; }
step() { echo "$(c '1;34')▶$(c 0) $*"; }
ok()   { echo "$(c '1;32')✓$(c 0) $*"; }
warn() { echo "$(c '1;33')⚠$(c 0) $*" >&2; }
die()  { echo "$(c '1;31')✗ $*$(c 0)" >&2; exit 1; }

# ── Args ───────────────────────────────────────────────────────────────────────
VARIANT="${1:-}"; PACK=0
[[ "${2:-}" == "--pack" ]] && PACK=1
case "$VARIANT" in
  vanilla|kowsu|ksunext) ;;
  *) die "usage: ./build.sh <vanilla|kowsu|ksunext> [--pack]" ;;
esac

KOUT="${KOUT:-$PROJ/.build/out-$VARIANT}"
LOG="$PROJ/.build/logs/build-$VARIANT-$(date +%Y%m%d-%H%M%S).log"
MK=( make -C "$KERNEL_SRC" O="$KOUT" ARCH=arm64 LLVM=1 LLVM_IAS=1
     CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- )
export PATH="$BUILD_TOOLS:$CLANG_DIR/bin:$PATH"
# Kernel branding (shows in `uname -r` / Settings → Kernel version, and /proc/version).
# Pure strings — KMI-inert (same_magic strips the version token at module load).
BRAND="${BRAND:-Riza}"
case "$VARIANT" in vanilla) VTAG=vanilla ;; kowsu) VTAG=kowsu ;; ksunext) VTAG=ksunext ;; esac
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-riza}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-RizaKernel}"
# The AOSP build-tools ship a hermetic python3 (no pyelftools) that now shadows
# PATH — pin a system python that actually has elftools for the KMI cross-check.
SYSPY=""
for p in /usr/bin/python3 /usr/local/bin/python3 python3; do
  "$p" -c 'import elftools' 2>/dev/null && { SYSPY="$p"; break; }
done
[[ -n "$SYSPY" ]] || die "no python3 with pyelftools found (needed for KMI cross-check): pip install pyelftools"

# ── Preflight ──────────────────────────────────────────────────────────────────
hdr "Itel RS4 kernel build — variant: $VARIANT"
# device.conf gate — the tool refuses to build without a valid per-device KMI target.
[[ -f "$DEVICE_CONF" ]] || die "device.conf not found ($DEVICE_CONF).
  Create it and set MODULE_LAYOUT to YOUR device's KMI value before building."
[[ "$MODULE_LAYOUT" =~ ^0x[0-9a-fA-F]{8}$ ]] || die "device.conf: MODULE_LAYOUT is empty or not a CRC like 0x7c24b32d — set YOUR device's KMI module_layout first.
  Obtain it from your device's own stock vendor_dlkm modules:
    modprobe --dump-modversions <any_vendor>.ko | awk '\$2==\"module_layout\"{print \$1}'
  (all the vendor .ko carry the same CRC — it's the exact ABI the blobs demand)."
ok "device: KMI target module_layout = $MODULE_LAYOUT (from $(basename "$DEVICE_CONF"))"
[[ -d "$KERNEL_SRC" ]]      || die "kernel source missing: $KERNEL_SRC"
[[ -f "$STOCK_CONFIG" ]]    || die "stock config missing: $STOCK_CONFIG (extract-ikconfig from boot.img)"
[[ -x "$CLANG_DIR/bin/clang" ]] || die "clang missing: $CLANG_DIR/bin/clang"
grep -q '^CONFIG_CFI_CLANG=y' "$STOCK_CONFIG" || die "stock config lacks CFI_CLANG — wrong config, KMI would break"
ok "kernel $(awk '/^VERSION/{v=$3}/^PATCHLEVEL/{p=$3}/^SUBLEVEL/{s=$3}END{print v"."p"."s}' "$KERNEL_SRC/Makefile") @ $(git -C "$KERNEL_SRC" rev-parse --short HEAD 2>/dev/null)   clang $("$CLANG_DIR/bin/clang" --version | awk 'NR==1{print $NF}')"
mkdir -p "$KOUT" "$(dirname "$LOG")" "$PROJ/out/$VARIANT"

# ── Source prep (KSU/SusFS for the ksunext variant; git-revert on exit) ─────────
SOURCE_DIRTY=0
cleanup_source() {
  [[ "$SOURCE_DIRTY" == 1 ]] || return 0
  step "Reverting kernel source to pristine (git checkout + clean)"
  git -C "$KERNEL_SRC" checkout -- . 2>/dev/null || true
  # -ffd (double force) also removes the nested KernelSU-Next git repo setup.sh clones
  git -C "$KERNEL_SRC" clean -ffdq -e build.config.droidian 2>/dev/null || true
  ok "source restored"
}
trap cleanup_source EXIT

prepare_source() {
  [[ -z "$(git -C "$KERNEL_SRC" status --porcelain -uno)" ]] \
    || die "kernel source has uncommitted tracked changes — refuse to patch on top; inspect $KERNEL_SRC"
  SOURCE_DIRTY=1
  # BORE scheduler — applied to EVERY variant (KMI-safe KABI packing; default-on
  # via kernel.sched_bore). Innocent of the recovery bounce — that was built-in ZRAM.
  step "Applying BORE scheduler backport (apply-bore.sh)"
  [[ -x "$PROJ/apply-bore.sh" ]] || die "apply-bore.sh missing — BORE not staged yet"
  KERNEL_SRC="$KERNEL_SRC" PROJ="$PROJ" "$PROJ/apply-bore.sh"
  ok "BORE applied"
  case "$VARIANT" in
    kowsu)
      step "Integrating KoWSU (KOWX712) standalone (apply-kowsu.sh)"
      [[ -x "$PROJ/apply-kowsu.sh" ]] || die "apply-kowsu.sh missing — KoWSU integration not staged yet"
      KERNEL_SRC="$KERNEL_SRC" PROJ="$PROJ" "$PROJ/apply-kowsu.sh"
      ok "KoWSU integrated" ;;
    ksunext)
      step "Integrating KernelSU-Next v3.3.0 Wild + SusFS (apply-ksunext-susfs.sh)"
      [[ -x "$PROJ/apply-ksunext-susfs.sh" ]] || die "apply-ksunext-susfs.sh missing — KernelSU-Next integration not staged yet"
      KERNEL_SRC="$KERNEL_SRC" PROJ="$PROJ" "$PROJ/apply-ksunext-susfs.sh"
      ok "KernelSU-Next v3.3.0 + SusFS applied" ;;
    vanilla)
      ok "vanilla: BORE only (no root)" ;;
  esac
}

# ── Compose .config = stock + fragments ────────────────────────────────────────
compose_config() {
  hdr "Compose .config (stock base + fragments) — variant $VARIANT"
  cp "$STOCK_CONFIG" "$KOUT/.config"
  # Neutralize MTK's build-server whitelist abs path + disable ksym trim
  # (cosmetic to KMI; the abs path doesn't exist here so trim would fail).
  "$KERNEL_SRC/scripts/config" --file "$KOUT/.config" \
    --disable TRIM_UNUSED_KSYMS --set-str UNUSED_KSYMS_WHITELIST ""
  local frags=( "$PROJ/config/performance.fragment" "$PROJ/config/network.fragment"
                "$PROJ/config/bore.fragment" )
  [[ "$VARIANT" == "kowsu" ]]   && frags+=( "$PROJ/config/kowsu.fragment" )
  [[ "$VARIANT" == "ksunext" ]] && frags+=( "$PROJ/config/ksunext.fragment" )
  for f in "${frags[@]}"; do [[ -f "$f" ]] || die "fragment missing: $f"; done
  # Per-variant branding fragment: -$BRAND-$VTAG, git-hash suffix off.
  cat > "$KOUT/brand.fragment" <<EOF
CONFIG_LOCALVERSION="-$BRAND-$VTAG"
# CONFIG_LOCALVERSION_AUTO is not set
EOF
  # Empty .scmversion suppresses setlocalversion's trailing "+" (tree-ahead-of-tag
  # marker it adds when LOCALVERSION_AUTO is off) → clean "5.10.258-$BRAND-$VTAG".
  touch "$KERNEL_SRC/.scmversion"
  frags+=( "$KOUT/brand.fragment" )
  "$KERNEL_SRC/scripts/kconfig/merge_config.sh" -m -r -O "$KOUT" "$KOUT/.config" "${frags[@]}" >/dev/null
  if ! "${MK[@]}" olddefconfig > "$KOUT/olddefconfig.log" 2>&1; then
    tail -25 "$KOUT/olddefconfig.log" >&2; die "olddefconfig failed (see $KOUT/olddefconfig.log)"
  fi
  step "Gate config invariants (KMI must-haves)"
  for must in CONFIG_CFI_CLANG=y CONFIG_LTO_CLANG_FULL=y CONFIG_MODVERSIONS=y; do
    grep -q "^$must" "$KOUT/.config" || die "config invariant missing: $must — KMI would break"
  done
  ok "config composed: $(grep -c '=y' "$KOUT/.config") builtins; CFI+LTO+MODVERSIONS on"
}

# ── Build ──────────────────────────────────────────────────────────────────────
build_kernel() {
  hdr "Build vmlinux + Image (full CFI+LTO, ~20–30 min)"
  step "make -j$NPROC vmlinux Image.gz Image.lz4  (log: $LOG)"
  "${MK[@]}" -j"$NPROC" vmlinux Image.gz Image.lz4 2>&1 | tee "$LOG" \
    || die "kernel build failed — see $LOG"
  ok "build finished"
}

# ── KMI gate ───────────────────────────────────────────────────────────────────
kmi_gate() {
  hdr "KMI gate — must reproduce vendor ABI $MODULE_LAYOUT (device.conf)"
  local got; got="$(awk '$2=="module_layout"{print $1}' "$KOUT/vmlinux.symvers")"
  [[ "$got" == "$MODULE_LAYOUT" ]] \
    && ok "module_layout = $got — MATCHES the device KMI target" \
    || die "module_layout = $got, expected $MODULE_LAYOUT — KMI BROKEN, do NOT ship"
  # Full cross-check needs the stock vendor_dlkm .ko. Optional: a porter may have
  # the module_layout but not the .ko yet → module_layout check only, with a warning.
  if [[ -n "$VENDOR_KO_DIR" && -d "$VENDOR_KO_DIR" ]]; then
    step "Full CRC cross-check vs $VENDOR_KO_DIR"
    "$SYSPY" "$PROJ/lib/kmi_check.py" "$KOUT/vmlinux.symvers" "$VENDOR_KO_DIR" \
      || die "vendor-module CRC mismatch — KMI broken"
  else
    warn "VENDOR_KO_DIR not set/found — skipping the full vendor-module CRC cross-check"
    warn "(module_layout matched, but set VENDOR_KO_DIR in device.conf for the strongest guarantee)"
  fi
}

# ── Publish Image artifacts ────────────────────────────────────────────────────
publish() {
  hdr "Publish → out/$VARIANT/"
  local o="$PROJ/out/$VARIANT"
  cp "$KOUT/arch/arm64/boot/Image"     "$o/Image"
  cp "$KOUT/arch/arm64/boot/Image.gz"  "$o/Image.gz"
  cp "$KOUT/arch/arm64/boot/Image.lz4" "$o/Image.lz4"
  cp "$KOUT/.config"                   "$o/kernel.config"
  cp "$KOUT/vmlinux.symvers"           "$o/vmlinux.symvers"
  ( cd "$o" && sha256sum Image Image.gz Image.lz4 > SHA256SUMS )
  ok "Image (sha $(sha256sum "$o/Image" | cut -c1-12)…), Image.gz, Image.lz4, kernel.config → $o/"
  local krel; krel="$(cat "$KOUT/include/config/kernel.release" 2>/dev/null || echo '?')"
  ok "kernel.release = $krel"
}

# ── Packaging (AnyKernel3 zip + stock boot.img) ────────────────────────────────
package() {
  [[ "$PACK" == 1 ]] || return 0
  if [[ -x "$PROJ/package.sh" ]]; then
    VARIANT="$VARIANT" PROJ="$PROJ" BOOT_IMG="$BOOT_IMG" "$PROJ/package.sh"
  else
    warn "package.sh not present yet — skipping AnyKernel3/boot.img (Image artifacts are ready)"
  fi
}

# ── Run ────────────────────────────────────────────────────────────────────────
prepare_source
compose_config
build_kernel
kmi_gate
publish
package
hdr "DONE — variant $VARIANT"
