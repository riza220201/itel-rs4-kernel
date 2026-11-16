// SPDX-License-Identifier: GPL-2.0
/*
 * rs4_memreclaim - LIVE TEST ONLY: mainline 5.19's memory.reclaim (94968384dde1,
 * "memcg: introduce per-memcg reclaim interface") registered from a module on the
 * running 5.10 kernel, to prove what v11's in-tree backport does before building it.
 *
 * Android 16's CachedAppOptimizer.compactSystem() applies the CompactFull task
 * profile to every non-app process: libprocessgroup reads memory.current and writes
 * it to memory.reclaim. 5.10 has no memory.reclaim, so system compaction does nothing.
 *
 * Differences from the in-tree patch, both forced by unexported symbols:
 *  - page_counter_memparse() is open-coded (same body, max string "");
 *  - no lru_add_drain_all() before the final retry.
 * No module_exit: cgroup_rm_cftypes() is not exported, so this cannot be unloaded.
 * The cftypes stay registered until reboot.
 */
#include <linux/module.h>
#include <linux/cgroup.h>
#include <linux/memcontrol.h>
#include <linux/page_counter.h>
#include <linux/sched/signal.h>
#include <linux/swap.h>
#include <linux/kernfs.h>

#define RS4_MAX_RECLAIM_RETRIES 16	/* mm/internal.h MAX_RECLAIM_RETRIES */

static ssize_t rs4_memory_reclaim(struct kernfs_open_file *of, char *buf,
				  size_t nbytes, loff_t off)
{
	struct mem_cgroup *memcg = mem_cgroup_from_css(of_css(of));
	unsigned int nr_retries = RS4_MAX_RECLAIM_RETRIES;
	unsigned long nr_to_reclaim, nr_reclaimed = 0;
	char *end;
	u64 bytes;

	buf = strstrip(buf);
	if (!strcmp(buf, "")) {			/* page_counter_memparse(buf, "", ...) */
		nr_to_reclaim = PAGE_COUNTER_MAX;
	} else {
		bytes = memparse(buf, &end);
		if (*end != '\0')
			return -EINVAL;
		nr_to_reclaim = min(bytes / PAGE_SIZE, (u64)PAGE_COUNTER_MAX);
	}

	while (nr_reclaimed < nr_to_reclaim) {
		unsigned long reclaimed;

		if (signal_pending(current))
			return -EINTR;

		reclaimed = try_to_free_mem_cgroup_pages(memcg,
						nr_to_reclaim - nr_reclaimed,
						GFP_KERNEL, true);

		if (!reclaimed && !nr_retries--)
			return -EAGAIN;

		nr_reclaimed += reclaimed;
	}

	return nbytes;
}

static struct cftype rs4_memory_files[] = {
	{
		.name = "reclaim",
		.flags = CFTYPE_NS_DELEGATABLE,
		.write = rs4_memory_reclaim,
	},
	{ }	/* terminate */
};

static int __init rs4_memreclaim_init(void)
{
	int ret = cgroup_add_dfl_cftypes(&memory_cgrp_subsys, rs4_memory_files);

	pr_info("rs4_memreclaim: memory.reclaim (live test) registered: %d\n", ret);
	return ret;
}
module_init(rs4_memreclaim_init);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("LIVE TEST: mainline 5.19 memory.reclaim on 5.10 (v11 backport proof)");
