#!/usr/bin/env bash
# Integrate official KernelSU v3.2.5 + SusFS v2.2.0 into $KERNEL_SRC (called by
# build.sh for the ksu variant, on a pristine git tree; git-reverted afterwards).
#
# PINNED MATCHED PAIR (both patches verified 0-fail):
#   - official KernelSU tag v3.2.5  -> kernel reports KSU version 32525, which is
#     EXACTLY the downloadable v3.2.5 manager APK (KernelSU_v3.2.5_32525-release.apk)
#     -> no manager/kernel version mismatch (that was why `su` failed on-device).
#   - simonpunk SusFS commit 81f01bc (v2.2.0) -> newest SusFS that still applies
#     cleanly to KSU v3.2.5 (its 10_ vs v3.2.5 = 0 fails; 50_ vs kernel = 0 fails).
#
# Why not KSU-Next: simonpunk SusFS only ever targets *official* KernelSU (every
# commit is "sync with official KernelSU"); it fails ~18 hunks on KSU-Next at any
# age. No SusFS targets KSU-Next, so official KSU is the only clean pairing here.
set -euo pipefail
KERNEL_SRC="${KERNEL_SRC:?}"; PROJ="${PROJ:?}"
KSU_REF="${KSU_REF:-v3.2.5}"                  # official KSU tag == manager APK version
SUSFS_REF="${SUSFS_REF:-81f01bc}"             # simonpunk susfs commit matched to v3.2.5
KSU_SETUP="$PROJ/.build/ksu-official/kernel/setup.sh"
SUSFS="$PROJ/.build/susfs-hist"
KVER="gki-android12-5.10"
say(){ echo "  [ksu] $*"; }
die(){ echo "✗ [ksu] $*" >&2; exit 1; }

[[ -f "$KSU_SETUP" ]] || die "official KSU setup.sh missing at $KSU_SETUP"
[[ -d "$SUSFS/.git" ]] || die "susfs history clone missing at $SUSFS"
git -C "$SUSFS" checkout -q "$SUSFS_REF" 2>/dev/null || die "susfs ref $SUSFS_REF unavailable (need full-ish susfs-hist clone)"
PATCH50="$SUSFS/kernel_patches/50_add_susfs_in_${KVER}.patch"
PATCH10="$SUSFS/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
[[ -f "$PATCH50" && -f "$PATCH10" ]] || die "susfs patches not found at $SUSFS_REF"

# 1) official KernelSU @ v3.2.5.
# Run with SYSTEM coreutils first on PATH: setup.sh uses `realpath --relative-to`
# for the drivers/kernelsu symlink; the AOSP build-tools realpath (on the build's
# PATH) is a busybox variant lacking --relative-to → broken symlink → olddefconfig
# "can't open drivers/kernelsu/Kconfig".
say "setup official KernelSU @ $KSU_REF"
( cd "$KERNEL_SRC" && PATH="/usr/bin:/bin:$PATH" sh "$KSU_SETUP" "$KSU_REF" ) || die "KSU setup.sh failed"
[[ -e "$KERNEL_SRC/KernelSU" ]] || die "KernelSU dir not created"
[[ -f "$KERNEL_SRC/drivers/kernelsu/Kconfig" ]] \
  || die "drivers/kernelsu/Kconfig unresolved — symlink broken (realpath --relative-to?)"

# 2) susfs files into the kernel tree
say "copy susfs fs/ + include/ files (@ $SUSFS_REF)"
cp "$SUSFS/kernel_patches/fs/susfs.c"                 "$KERNEL_SRC/fs/"
cp "$SUSFS/kernel_patches/include/linux/susfs.h"      "$KERNEL_SRC/include/linux/"
cp "$SUSFS/kernel_patches/include/linux/susfs_def.h"  "$KERNEL_SRC/include/linux/"

# 3) kernel-side patch (inline hooks in fs/, kernel/, mm/, security/)
say "apply $(basename "$PATCH50") at kernel root"
( cd "$KERNEL_SRC" && patch -p1 --no-backup-if-mismatch --forward < "$PATCH50" ) \
  || die "50_ patch failed — inspect .rej in $KERNEL_SRC"
[[ -z "$(find "$KERNEL_SRC" -name '*.rej' 2>/dev/null | head -1)" ]] || die "50_ patch .rej — fixup needed"

# 4) KSU-side patch
say "apply $(basename "$PATCH10") inside KernelSU"
( cd "$KERNEL_SRC/KernelSU" && patch -p1 --no-backup-if-mismatch --forward < "$PATCH10" ) \
  || die "10_ patch failed — KSU_REF/SUSFS_REF pair mismatch"
[[ -z "$(find "$KERNEL_SRC/KernelSU" -name '*.rej' 2>/dev/null | head -1)" ]] || die "10_ patch .rej — version mismatch"

say "official KernelSU $KSU_REF + SusFS v2.2.0 ($SUSFS_REF) integrated cleanly"
