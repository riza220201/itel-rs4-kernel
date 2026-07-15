#!/usr/bin/env bash
# Integrate KoWSU (KOWX712/KernelSU) into $KERNEL_SRC as a self-contained built-in
# driver (called by build.sh for the kowsu variant, on a pristine git tree that is
# git-reverted afterwards).
#
# WHY KoWSU standalone (no SusFS):
#   KoWSU is a fully-restructured KSU fork (core/feature/hook/infra/… ; it has none
#   of core_hook.c / ksu.h / ksud.c that simonpunk SusFS's 10_ patch targets), so
#   SusFS cannot be applied. KoWSU instead ships its OWN kernel-side hiding:
#   feature/kernel_umount.c (unmounts root mounts per-app), feature/selinux_hide.c,
#   feature/sucompat.c. That is the intended "no-SusFS" design of this fork.
#
# WHY it is KMI-safe by construction:
#   setup only symlinks drivers/kernelsu → the KoWSU kernel/ dir and appends one
#   line each to drivers/Makefile + drivers/Kconfig. It patches NO core kernel file,
#   so it cannot change task_struct / any vendor-referenced struct → module_layout
#   stays 0x7c24b32d. The build's KMI gate re-verifies regardless.
#
# VERSION MATCHING (the make-or-break for root, learned the hard way in v1):
#   KoWSU reports version = 30000 + git-rev-count. Pinned tag v3.2.5 → 32525, which
#   is deliberately aligned with the official-KSU numbering. The KoWSU manager must
#   be >= the kernel version, so pinning the kernel LOW (32525) means ANY current
#   KOWX712 manager APK (v3.2.5 or newer) grants root. Full (non-shallow) local
#   clone so rev-count is correct with NO build-time network + NO version drift.
set -euo pipefail
KERNEL_SRC="${KERNEL_SRC:?}"; PROJ="${PROJ:?}"
# sources.lock is the single source of truth for the pinned commit set.
LOCKFILE="${LOCKFILE:-$PROJ/sources.lock}"
# shellcheck source=/dev/null
[[ -f "$LOCKFILE" ]] && source "$LOCKFILE"          # pins: KOWSU_REF (SHA), KOWSU_VER_EXPECT
KOWSU_SRC="${KOWSU_SRC:-$PROJ/.build/kowsu-ksu}"   # full local clone of KOWX712/KernelSU
KOWSU_REF="${KOWSU_REF:-v3.2.5}"                    # pinned SHA (sources.lock); falls back to tag → 32525
KOWSU_VER_EXPECT="${KOWSU_VER_EXPECT:-32525}"
say(){ echo "  [kowsu] $*"; }
die(){ echo "✗ [kowsu] $*" >&2; exit 1; }

[[ -f "$LOCKFILE" ]] || say "⚠ sources.lock not found — falling back to the v3.2.5 tag (not SHA-pinned)"
[[ -d "$KOWSU_SRC/.git" ]] || die "KoWSU clone missing at $KOWSU_SRC (git clone https://github.com/KOWX712/KernelSU)"
[[ -d "$KOWSU_SRC/kernel" ]] || die "$KOWSU_SRC/kernel not found — wrong repo?"

# Pin deterministically (detached HEAD at the tag; no pull → no version drift).
say "pin KoWSU @ $KOWSU_REF"
git -C "$KOWSU_SRC" checkout -q "$KOWSU_REF" 2>/dev/null || die "ref $KOWSU_REF not in clone (need full history for rev-count)"
[[ -z "$(git -C "$KOWSU_SRC" status --porcelain 2>/dev/null)" ]] || die "KoWSU clone is dirty — refuse (would skew rev-count/version)"
if git -C "$KOWSU_SRC" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
  die "KoWSU clone is shallow — rev-count/version would be wrong; re-clone full"
fi
KVER=$(( 30000 + $(git -C "$KOWSU_SRC" rev-list --count HEAD) ))
say "KoWSU reported version will be $KVER (git-rev-count $((KVER-30000)))"
[[ "$KVER" == "$KOWSU_VER_EXPECT" ]] \
  || die "version $KVER != expected $KOWSU_VER_EXPECT — manager-match would break; check KOWSU_REF"

# Wire in as a built-in driver (mirror KOWX712 setup.sh's 3 effects, pinned+offline).
say "symlink drivers/kernelsu → $KOWSU_SRC/kernel"
ln -sfn "$KOWSU_SRC/kernel" "$KERNEL_SRC/drivers/kernelsu"

DMK="$KERNEL_SRC/drivers/Makefile"; DKC="$KERNEL_SRC/drivers/Kconfig"
grep -q 'kernelsu' "$DMK" || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DMK"
# drivers/Kconfig has exactly one top-level `endmenu`; insert the source line
# before it (classic KSU setup.sh form).
grep -q 'drivers/kernelsu/Kconfig' "$DKC" \
  || sed -i '/^endmenu/i\source "drivers/kernelsu/Kconfig"' "$DKC"

# Guards: the driver must actually resolve, or olddefconfig dies cryptically later.
[[ -e "$KERNEL_SRC/drivers/kernelsu/Kconfig" ]] \
  || die "drivers/kernelsu/Kconfig unresolved — symlink broken"
grep -q 'kernelsu' "$DMK" || die "drivers/Makefile not wired"
grep -q 'drivers/kernelsu/Kconfig' "$DKC" || die "drivers/Kconfig not wired"

say "KoWSU $KOWSU_REF (v$KVER) integrated (standalone, no SusFS — uses KoWSU native hiding)"
