/* SPDX-License-Identifier: GPL-2.0 */
/*
 * CPU limit driver for MTK
 *
 * Copyright (c) 2022 Samsung Electronics Co., Ltd.
 *
 * Author: Sangyoung Son <hello.son@samsung.com>
 *
 * Change limit driver code for MTK chipset by Jonghyeon Cho
 * Author: Jonghyeon Cho <jongjaaa.cho@samsung.com>
 *
 * Ported to the itel RS4 (MT6789) GKI android12-5.10 kernel: see
 * drivers/cpufreq/cpufreq_limit.c for what changed and why.
 */

#ifndef __LINUX_CPUFREQ_LIMIT_H__
#define __LINUX_CPUFREQ_LIMIT_H__

#define CPUFREQ_LIMIT_TSIZE	64

struct cpufreq_limit_parameter {
	unsigned int unified_table[CPUFREQ_LIMIT_TSIZE];
	unsigned int num_cpu;
	unsigned int freq_count;
	unsigned int ltl_cpu_start;
	unsigned int big_cpu_start;
	unsigned int ltl_max_freq;
	unsigned int ltl_min_lock_freq;
	unsigned int big_max_lock_freq;
	unsigned int ltl_divider;
	unsigned int over_limit;
};

enum {
	DVFS_USER_ID = 0,
	DVFS_TOUCH_ID,
	DVFS_FINGER_ID,
	DVFS_OVERLIMIT_ID,
	DVFS_MAX_ID
};

/*
 * Request a unified-frequency min lock for @id (Samsung API). @freq is a
 * value from cpufreq_table; (unsigned int)-1 releases the lock. Returns
 * -EAGAIN until both CPU clusters have registered their cpufreq policies.
 */
extern int set_freq_limit(unsigned int id, unsigned int freq);

#endif /* __LINUX_CPUFREQ_LIMIT_H__ */
