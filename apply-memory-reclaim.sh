#!/usr/bin/env bash
# Apply the memory.reclaim backport (mainline 5.19 94968384dde1) to $KERNEL_SRC (called by
# build.sh for ALL variants, on a pristine git tree that is git-reverted afterwards).
#
# Android 16's system compaction (CachedAppOptimizer.compactSystem -> CompactFull task
# profile) writes each process's memory.current into memory.reclaim; 5.10 lacks the file,
# so it did nothing. Details and what is deliberately NOT taken: the patch header.
#
# KMI-safe: a static handler and one entry in the static memory_files[] array; no exported
# symbol or struct changes. The build's KMI gate re-verifies; build.sh checks
# memory_reclaim is in System.map.
set -euo pipefail
KERNEL_SRC="${KERNEL_SRC:?}"; PROJ="${PROJ:?}"
PATCH="${MEMORY_RECLAIM_PATCH:-$PROJ/patches/memory-reclaim-5.10.patch}"
say(){ echo "  [memory.reclaim] $*"; }
die(){ echo "✗ [memory.reclaim] $*" >&2; exit 1; }

[[ -f "$PATCH" ]] || die "patch missing at $PATCH"
M="$KERNEL_SRC/mm/memcontrol.c"

# Sanity: not there already, and the anchors and callees the handler relies on are as on 694b9714.
! grep -q '^static ssize_t memory_reclaim(' "$M" \
  || die "memory_reclaim already defined — kernel source not pristine, or upstream added it"
grep -q '^static ssize_t memory_oom_group_write(struct kernfs_open_file \*of,$' "$M" \
  || die "mm/memcontrol.c anchor (memory_oom_group_write) changed — re-port memory.reclaim"
grep -q '^static struct cftype memory_files\[\] = {$' "$M" \
  || die "mm/memcontrol.c anchor (memory_files[]) changed — re-port memory.reclaim"
grep -q '^unsigned long try_to_free_mem_cgroup_pages(struct mem_cgroup \*memcg,$' "$KERNEL_SRC/mm/vmscan.c" \
  || die "try_to_free_mem_cgroup_pages() signature changed — re-check the handler's call"
grep -A3 '^unsigned long try_to_free_mem_cgroup_pages(struct mem_cgroup \*memcg,$' "$KERNEL_SRC/mm/vmscan.c" \
  | grep -q 'bool may_swap)' || die "try_to_free_mem_cgroup_pages() no longer takes bool may_swap"

say "apply $(basename "$PATCH")"
( cd "$KERNEL_SRC" && patch -p1 --no-backup-if-mismatch --forward --dry-run < "$PATCH" >/dev/null 2>&1 ) \
  || die "patch does not apply cleanly (dry-run failed) — kernel source drifted"
( cd "$KERNEL_SRC" && patch -p1 --no-backup-if-mismatch --forward < "$PATCH" ) \
  || die "patch failed"
[[ -z "$(find "$KERNEL_SRC" -name '*.rej' 2>/dev/null | head -1)" ]] || die ".rej present — fixup needed"

# Guards: the handler and its cftype entry must both be in place.
grep -q '^static ssize_t memory_reclaim(struct kernfs_open_file \*of, char \*buf,$' "$M" \
  || die "memory_reclaim() missing after patch"
grep -B1 -A2 '\.name = "reclaim",' "$M" | grep -q '\.write = memory_reclaim,' \
  || die "memory_files[] entry for \"reclaim\" missing after patch"

say "memory.reclaim backport applied (cgroup v2 memory controller)"
