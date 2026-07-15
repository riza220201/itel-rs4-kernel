#!/usr/bin/env bash
# Integrate KernelSU-Next (v3.3.0 "Wild" dev-susfs) + SusFS v2.2.0 into $KERNEL_SRC
# (called by build.sh for the ksunext variant, on a pristine git tree that is
# git-reverted afterwards). This is the current root variant — it replaced the old
# official-KernelSU `ksu` variant, and supersedes the earlier v3.1.0-legacy-susfs +
# SusFS v2.0.0 recipe (documented in JOURNAL.md if ever needed).
#
# RECIPE (mirrors WildKernels/GKI_KernelSU_SUSFS — the maintained current combo):
#   * KSU side: pershoot/KernelSU-Next `dev-susfs` ("Wild KSU") — current KSU-Next
#     v3.3.0 (restructured core/feature/hook/supercall) with SusFS *in-driver*, so
#     NO `10_` patch. + WildKernels `static.patch` (de-statics 3 selinux_hide fns so
#     the SusFS selinux hooks link).
#   * Kernel side: stock simonpunk SusFS v2.2.0 (gki-android12-5.10) + pershoot's 2
#     extension cherry-picks (staged in .build/susfs-wild) — the matched susfs.c the
#     dev-susfs driver calls. 50_ applies 0-fail on this 5.10.258 tree; the
#     WildKernels "fake patch" source-context hacks all gate on sublevel <=117/<=209,
#     so they're skipped here (sublevel 258).
#
# KMI-safe by construction (self-contained driver + hlist/thread-flag susfs, no
# task_struct/inode growth) → module_layout 0x7c24b32d; the build gate re-verifies.
set -euo pipefail
KERNEL_SRC="${KERNEL_SRC:?}"; PROJ="${PROJ:?}"
# sources.lock is the single source of truth for the pinned commit set — sourcing it
# fixes exactly which KSU/SusFS commits this variant is built from (was the moving
# `dev-susfs`/branch tips). Env vars set before this still win via the ${VAR:-...}.
LOCKFILE="${LOCKFILE:-$PROJ/sources.lock}"
# shellcheck source=/dev/null
[[ -f "$LOCKFILE" ]] && source "$LOCKFILE"
WILDKSU_SRC="${WILDKSU_SRC:-$PROJ/.build/wildksu}"          # pershoot KernelSU-Next clone
WILDKSU_REF="${WILDKSU_REF:-dev-susfs}"                     # pinned SHA (sources.lock); falls back to branch tip
WILDKSU_VERBASE="${WILDKSU_VERBASE:-}"                      # version-anchor commit (sources.lock)
WILDKSU_VER_EXPECT="${WILDKSU_VER_EXPECT:-}"               # expected 30000+rev-count; drift => die
SUSFS="${SUSFS:-$PROJ/.build/susfs-wild}"                   # simonpunk 5.10 + pershoot cherry-picks
SUSFS_REF="${SUSFS_REF:-}"                                  # pinned SHA (sources.lock); empty => use tree as-is
STATIC_PATCH="${STATIC_PATCH:-$PROJ/patches/ksunext-static.patch}"
KVER="gki-android12-5.10"
say(){ echo "  [ksunext] $*"; }
die(){ echo "✗ [ksunext] $*" >&2; exit 1; }

[[ -f "$LOCKFILE" ]] || say "⚠ sources.lock not found — falling back to branch tips (NOT reproducible)"
[[ -d "$WILDKSU_SRC/.git" ]] || die "Wild KSU clone missing at $WILDKSU_SRC (git clone https://github.com/pershoot/KernelSU-Next)"
[[ -d "$WILDKSU_SRC/kernel" ]] || die "$WILDKSU_SRC/kernel not found — wrong repo?"
# Pin SusFS to the exact commit (sources.lock) before reading its 50_ patch / files.
if [[ -n "$SUSFS_REF" && -d "$SUSFS/.git" ]]; then
  git -C "$SUSFS" checkout -q -- . 2>/dev/null || true ; git -C "$SUSFS" clean -fdq 2>/dev/null || true
  git -C "$SUSFS" checkout -q "$SUSFS_REF" 2>/dev/null \
    || die "SusFS ref ${SUSFS_REF:0:12} not in $SUSFS — fetch it or fix sources.lock"
  say "pin SusFS (simonpunk gki-android12-5.10 + picks) @ ${SUSFS_REF:0:12}"
fi
PATCH50="$SUSFS/kernel_patches/50_add_susfs_in_${KVER}.patch"
[[ -f "$PATCH50" ]] || die "susfs-wild 50_ patch missing at $PATCH50 (stage .build/susfs-wild)"
[[ -f "$STATIC_PATCH" ]] || die "static.patch missing at $STATIC_PATCH"

# 1) Pin Wild KSU to the exact commit (sources.lock). Reset the working tree FIRST so
# a leftover static.patch from a prior/crashed run can't block the checkout, then
# re-apply it fresh below → deterministic across reruns. Version is read from
# committed history (rev-list --count), unaffected by the working-tree static.patch.
if git -C "$WILDKSU_SRC" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
  die "Wild KSU clone is shallow — version rev-count would be wrong; re-clone full"
fi
say "pin Wild KSU (pershoot KernelSU-Next) @ ${WILDKSU_REF:0:12}"
git -C "$WILDKSU_SRC" checkout -q -- . 2>/dev/null || true ; git -C "$WILDKSU_SRC" clean -fdq
git -C "$WILDKSU_SRC" checkout -q "$WILDKSU_REF" 2>/dev/null || git -C "$WILDKSU_SRC" checkout -q "origin/$WILDKSU_REF" 2>/dev/null \
  || die "ref $WILDKSU_REF not in clone — fetch it or fix sources.lock"
# Version = 30000 + rev-count(version-anchor). Pinning to a SHA detaches HEAD, so the
# old branch-name derivation (dev-susfs → dev → merge-base) no longer applies — use
# the pinned WILDKSU_VERBASE (merge-base w/ dev = KSU-Next v3.3.0 HEAD → 33219). Fall
# back to the live branch derivation only if the lockfile pinned no anchor.
if [[ -n "$WILDKSU_VERBASE" ]]; then
  KVCOMMIT="$WILDKSU_VERBASE"
else
  KVBASE=$(git -C "$WILDKSU_SRC" rev-parse --abbrev-ref HEAD | sed 's:-.*::')
  KVCOMMIT=$(git -C "$WILDKSU_SRC" merge-base HEAD "refs/remotes/origin/$KVBASE" 2>/dev/null || echo HEAD)
fi
KVERNUM=$(( 30000 + $(git -C "$WILDKSU_SRC" rev-list --count "$KVCOMMIT") ))
[[ -z "$WILDKSU_VER_EXPECT" || "$KVERNUM" == "$WILDKSU_VER_EXPECT" ]] \
  || die "KSU version drift: computed $KVERNUM but sources.lock expects $WILDKSU_VER_EXPECT — WILDKSU_REF/VERBASE moved; reconcile sources.lock (and package.sh banner) before shipping"
say "Wild KSU-Next reported version = $KVERNUM (manager must be >= this; v3.3.0 manager matches)"
say "apply WildKernels static.patch (de-static selinux_hide fns)"
( cd "$WILDKSU_SRC" && patch -p1 --no-backup-if-mismatch --forward < "$STATIC_PATCH" ) \
  || die "static.patch failed on $WILDKSU_SRC"

# 2) Wire in as a built-in driver (symlink + Makefile/Kconfig; pinned+offline).
say "symlink drivers/kernelsu → $WILDKSU_SRC/kernel"
ln -sfn "$WILDKSU_SRC/kernel" "$KERNEL_SRC/drivers/kernelsu"
DMK="$KERNEL_SRC/drivers/Makefile"; DKC="$KERNEL_SRC/drivers/Kconfig"
grep -q 'kernelsu' "$DMK" || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DMK"
grep -q 'drivers/kernelsu/Kconfig' "$DKC" \
  || sed -i '/^endmenu/i\source "drivers/kernelsu/Kconfig"' "$DKC"
[[ -e "$KERNEL_SRC/drivers/kernelsu/Kconfig" ]] \
  || die "drivers/kernelsu/Kconfig unresolved — symlink broken"

# 3) SusFS v2.2.0(+pershoot) kernel-side: copy fs/ + headers, then apply the 50_.
# sublevel 258 > all WildKernels fake-patch gates (<=117/<=209) → no context hacks.
say "copy susfs.c + include headers (v2.2.0 + pershoot cherry-picks @ susfs-wild)"
cp "$SUSFS/kernel_patches/fs/"*                "$KERNEL_SRC/fs/"
cp "$SUSFS/kernel_patches/include/linux/"*     "$KERNEL_SRC/include/linux/"
say "apply $(basename "$PATCH50") at kernel root"
( cd "$KERNEL_SRC" && patch -p1 --no-backup-if-mismatch --forward < "$PATCH50" ) \
  || die "50_ patch failed — inspect .rej in $KERNEL_SRC"
[[ -z "$(find "$KERNEL_SRC" -name '*.rej' 2>/dev/null | head -1)" ]] || die "50_ patch .rej — fixup needed"

say "Wild KSU-Next $WILDKSU_REF (v$KVERNUM) + SusFS v2.2.0 integrated (no 10_ — SusFS in-driver)"
