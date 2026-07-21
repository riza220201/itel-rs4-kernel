#!/usr/bin/env bash
# Apply the ntsync (NT synchronization primitives) backport to $KERNEL_SRC (called
# by build.sh for ALL variants, on a pristine git tree that is git-reverted afterwards).
#
# ntsync = mainline drivers/misc/ntsync.c (v6.14 — the complete version: semaphores +
# mutexes + events + wait-all/wait-any), hand-backported to android12-5.10. It exposes
# a /dev/ntsync misc device that Wine (Winlator/Proton) uses to back Windows NT
# semaphores/mutexes/events with in-kernel objects, replacing the eventfd esync/fsync
# storms — the big Windows-game-under-emulation sync-overhead win.
#
# The only 5.10 delta is debug-only: mainline's generic lockdep_assert(cond), the
# no-CONFIG_LOCKDEP spelling of lockdep_is_held(), and the LOCK_STATE_* enum postdate
# 5.10 — a small shim inside ntsync.c provides them (compiles to nothing with LOCKDEP
# off, the production config). See the patch header + config/ntsync.fragment.
#
# WHY it is KMI-safe: a self-contained leaf misc driver — it exports NO symbols and
# touches NO core struct (no struct module / sched_entity / socket), so it is purely
# additive and cannot move module_layout or any vendor-referenced CRC. Unlike BORE it
# needs zero KABI gymnastics. The build's KMI gate re-verifies 198/198 every build.
set -euo pipefail
KERNEL_SRC="${KERNEL_SRC:?}"; PROJ="${PROJ:?}"
PATCH="${NTSYNC_PATCH:-$PROJ/patches/ntsync-5.10.patch}"
say(){ echo "  [ntsync] $*"; }
die(){ echo "✗ [ntsync] $*" >&2; exit 1; }

[[ -f "$PATCH" ]] || die "ntsync patch missing at $PATCH"

# Sanity: the anchors the patch relies on must exist (guards against a kernel bump
# silently shifting the Kconfig/Makefile hooks), and the driver must not already exist.
grep -q 'source "drivers/misc/c2port/Kconfig"' "$KERNEL_SRC/drivers/misc/Kconfig" \
  || die "drivers/misc/Kconfig anchor changed — re-port ntsync"
grep -q 'CONFIG_UID_SYS_STATS' "$KERNEL_SRC/drivers/misc/Makefile" \
  || die "drivers/misc/Makefile anchor changed — re-port ntsync"
[[ ! -e "$KERNEL_SRC/drivers/misc/ntsync.c" ]] \
  || die "drivers/misc/ntsync.c already present — kernel source not pristine"

say "apply $(basename "$PATCH")"
if ! ( cd "$KERNEL_SRC" && patch -p1 --no-backup-if-mismatch --forward --dry-run < "$PATCH" >/dev/null 2>&1 ); then
  die "ntsync patch does not apply cleanly (dry-run failed) — kernel source drifted"
fi
( cd "$KERNEL_SRC" && patch -p1 --no-backup-if-mismatch --forward < "$PATCH" ) \
  || die "ntsync patch failed"
[[ -z "$(find "$KERNEL_SRC" -name '*.rej' 2>/dev/null | head -1)" ]] || die "ntsync .rej present — fixup needed"

# Guards: the driver, its uapi header, and the Kconfig/Makefile wiring must be present.
[[ -f "$KERNEL_SRC/drivers/misc/ntsync.c" ]]        || die "ntsync.c not created by patch"
[[ -f "$KERNEL_SRC/include/uapi/linux/ntsync.h" ]]  || die "uapi/linux/ntsync.h not created by patch"
grep -q 'config NTSYNC' "$KERNEL_SRC/drivers/misc/Kconfig"   || die "NTSYNC Kconfig missing"
grep -q 'ntsync.o' "$KERNEL_SRC/drivers/misc/Makefile"       || die "ntsync.o Makefile rule missing"

say "ntsync backport applied (KMI-safe leaf driver; CONFIG_NTSYNC=y → /dev/ntsync)"
