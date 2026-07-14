#!/usr/bin/env bash
# Apply the BORE scheduler backport to $KERNEL_SRC (called by build.sh for ALL
# variants, on a pristine git tree that is git-reverted afterwards).
#
# BORE = Burst-Oriented Response Enhancer (firelzrd/bore-scheduler bore5.1.0),
# hand-backported to android12-5.10. Minimal port: no atavistic fork inheritance.
#
# WHY it is KMI-safe: the per-entity burst state is packed into sched_entity's
# GKI KABI-reserved slots via ANDROID_KABI_USE(). Under __GENKSYMS__ that macro
# collapses to the original `u64 android_kabi_reservedN`, so genksyms computes
# byte-identical CRCs (and module_layout) whether BORE is on or off → the 198
# vendor modules still load. The build's KMI gate re-verifies this every build.
#
# Runtime toggle: kernel.sched_bore sysctl (default 1). Set 0 to fall back to
# stock CFS without reflashing.
set -euo pipefail
KERNEL_SRC="${KERNEL_SRC:?}"; PROJ="${PROJ:?}"
PATCH="${BORE_PATCH:-$PROJ/patches/bore-5.10-kmi.patch}"
say(){ echo "  [bore] $*"; }
die(){ echo "✗ [bore] $*" >&2; exit 1; }

[[ -f "$PATCH" ]] || die "BORE patch missing at $PATCH"

# Sanity: the anchors BORE relies on must exist unmodified (guards against a
# kernel-source bump silently shifting the hooks).
grep -q 'ANDROID_KABI_RESERVE(1);' "$KERNEL_SRC/include/linux/sched.h" \
  || die "sched_entity KABI-reserved slots not found — kernel changed, re-port BORE"
grep -q 'curr->vruntime += calc_delta_fair(delta_exec, curr);' "$KERNEL_SRC/kernel/sched/fair.c" \
  || die "update_curr anchor changed — re-port BORE"

say "apply $(basename "$PATCH")"
if ! ( cd "$KERNEL_SRC" && patch -p1 --no-backup-if-mismatch --forward --dry-run < "$PATCH" >/dev/null 2>&1 ); then
  die "BORE patch does not apply cleanly (dry-run failed) — kernel source drifted"
fi
( cd "$KERNEL_SRC" && patch -p1 --no-backup-if-mismatch --forward < "$PATCH" ) \
  || die "BORE patch failed"
[[ -z "$(find "$KERNEL_SRC" -name '*.rej' 2>/dev/null | head -1)" ]] || die "BORE .rej present — fixup needed"

# Guards: the packing + Kconfig must be present post-apply.
grep -q 'ANDROID_KABI_USE(1, u64 burst_time)' "$KERNEL_SRC/include/linux/sched.h" \
  || die "BORE KABI packing not applied to sched_entity"
grep -q 'config SCHED_BORE' "$KERNEL_SRC/init/Kconfig" || die "SCHED_BORE Kconfig missing"

say "BORE backport applied (KMI-safe; kernel.sched_bore runtime toggle, default on)"
