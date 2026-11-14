#!/usr/bin/env bash
# Apply the epoll_pwait2 (syscall 441) backport to $KERNEL_SRC (called by build.sh for
# ALL variants, on a pristine git tree that is git-reverted afterwards).
#
# Android 16 libgui calls epoll_pwait2 (Linux 5.11) with no fallback; on 5.10 the ENOSYS
# makes BLASTBufferQueue's buffer-release wait spin a core. This is mainline 7cdf7c20e971 +
# 58169a52ebc9 + b0a0c2615f6f + 450f68e2425e (details in the patch header).
#
# KMI-safe: no exported symbol and no struct changes. Slot 441 already exists in both
# syscall tables (GKI sizes them at 449), so neither table changes size. The build's KMI
# gate re-verifies, and build.sh checks the two syscall entry points are in System.map.
set -euo pipefail
KERNEL_SRC="${KERNEL_SRC:?}"; PROJ="${PROJ:?}"
PATCH="${EPOLL_PWAIT2_PATCH:-$PROJ/patches/epoll_pwait2-5.10.patch}"
say(){ echo "  [epoll_pwait2] $*"; }
die(){ echo "✗ [epoll_pwait2] $*" >&2; exit 1; }

[[ -f "$PATCH" ]] || die "patch missing at $PATCH"

# Sanity: the tree must not have it already, and the table must still end where the
# patch expects (440 process_madvise, then the 448 process_mrelease backport, 449 slots).
! grep -q '__NR_epoll_pwait2' "$KERNEL_SRC/include/uapi/asm-generic/unistd.h" \
  || die "__NR_epoll_pwait2 already defined — kernel source not pristine, or upstream added it"
grep -q '^#define __NR_syscalls 449$' "$KERNEL_SRC/include/uapi/asm-generic/unistd.h" \
  || die "__NR_syscalls is no longer 449 — the syscall table changed, re-check the backport"
grep -q '^#define __NR_compat_syscalls[[:space:]]*449$' "$KERNEL_SRC/arch/arm64/include/asm/unistd.h" \
  || die "__NR_compat_syscalls is no longer 449 — the compat table changed, re-check the backport"
grep -q '^static inline struct timespec64 ep_set_mstimeout(long ms)$' "$KERNEL_SRC/fs/eventpoll.c" \
  || die "fs/eventpoll.c anchor (ep_set_mstimeout) changed — re-port epoll_pwait2"

say "apply $(basename "$PATCH")"
( cd "$KERNEL_SRC" && patch -p1 --no-backup-if-mismatch --forward --dry-run < "$PATCH" >/dev/null 2>&1 ) \
  || die "patch does not apply cleanly (dry-run failed) — kernel source drifted"
( cd "$KERNEL_SRC" && patch -p1 --no-backup-if-mismatch --forward < "$PATCH" ) \
  || die "patch failed"
[[ -z "$(find "$KERNEL_SRC" -name '*.rej' 2>/dev/null | head -1)" ]] || die ".rej present — fixup needed"

# Guards: both syscall definitions and both table entries must be in place.
grep -q '^SYSCALL_DEFINE6(epoll_pwait2,' "$KERNEL_SRC/fs/eventpoll.c"        || die "sys_epoll_pwait2 missing"
grep -q '^COMPAT_SYSCALL_DEFINE6(epoll_pwait2,' "$KERNEL_SRC/fs/eventpoll.c" || die "compat_sys_epoll_pwait2 missing"
grep -q '^__SC_COMP(__NR_epoll_pwait2, sys_epoll_pwait2, compat_sys_epoll_pwait2)$' \
  "$KERNEL_SRC/include/uapi/asm-generic/unistd.h"                             || die "native table entry missing"
grep -q '^__SYSCALL(__NR_epoll_pwait2, compat_sys_epoll_pwait2)$' \
  "$KERNEL_SRC/arch/arm64/include/asm/unistd32.h"                             || die "compat table entry missing"

say "epoll_pwait2 backport applied (syscall 441, native + compat)"
