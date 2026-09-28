// SPDX-License-Identifier: GPL-2.0
/* driver/cpufreq/cpufreq_limit.c
 *
 * CPU limit driver for MTK
 *
 * Copyright (c) 2022 Samsung Electronics Co., Ltd.
 *
 * Author: Sangyoung Son <hello.son@samsung.com>
 *
 * Change limit driver code for MTK chipset by Jonghyeon Cho
 * Author: Jonghyeon Cho <jongjaaa.cho@samsung.com>
 *
 * This software is licensed under the terms of the GNU General Public
 * License version 2, as published by the Free Software Foundation, and
 * may be copied, distributed, and modified under those terms.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * ---------------------------------------------------------------------------
 * itel RS4 (S666LN, MT6789) port for the GKI android12-5.10 Riza kernel.
 *
 * WHY: the One UI 8 port runs Samsung's Game Optimizing Service, whose IPM
 * engine refuses to open a session without this interface ("Cannot
 * initialize CPU controllers without unified CPU support"), so Game
 * Booster's performance monitor reads 0 FPS / 0 RAM. Every Samsung kernel
 * has this driver; the itel kernel does not.
 *
 * BASE: Samsung's MTK driver from the Galaxy A15/A16 4G kernel (5.10, same
 * MT6789 SoC), with the parameter values of the Galaxy A17 4G device tree
 * (SM-A175F -- the port's donor):
 *     num_cpu 8, ltl_cpu_start 0, big_cpu_start 6,
 *     ltl_min_lock_freq 1150000, big_max_lock_freq 800000, ltl_divider 4
 * The sysfs ABI is Samsung's, unchanged:
 *     /sys/devices/system/cpu/cpufreq_limit/{cpufreq_table,cpufreq_min_limit,
 *         cpufreq_max_limit,over_limit}
 *     /sys/devices/system/cpu/cpufreq_limit/parameters/ (six tunables)
 *
 * WHAT CHANGED, AND WHY:
 *  1. No device-tree probe. The itel DT has no "cpufreq_limit" node and the
 *     MediaTek cpufreq driver is a vendor module that registers its policies
 *     long after this built-in driver initialises. So the requests are added
 *     from a cpufreq POLICY notifier when the little (CPU0) and big (CPU6)
 *     policies are created, and removed again if a policy goes away.
 *  2. One freq_qos request per cluster per id, not one per CPU. Samsung's
 *     driver added 8 per id but only ever updated the ltl/big start CPUs.
 *  3. Moving a request between the little-only range and the big range now
 *     releases the other cluster's previous lock. Samsung's 5.10 driver left
 *     it in place (a min lock above the split followed by one below it kept
 *     the big cluster pinned).
 *  4. set_freq_limit() is not exported: its only caller is built in.
 *
 * KMI: a new self-contained built-in driver; no struct or existing-symbol
 * change, so module_layout and the vendor CRCs are unaffected.
 */

#define pr_fmt(fmt) "cpufreq_limit: " fmt

#include <linux/cpu.h>
#include <linux/cpufreq.h>
#include <linux/cpufreq_limit.h>
#include <linux/err.h>
#include <linux/init.h>
#include <linux/kobject.h>
#include <linux/mutex.h>
#include <linux/pm_qos.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>

#define MAX_BUF_SIZE	1024

enum { CL_LTL = 0, CL_BIG, NR_CL };

static struct freq_qos_request min_req[DVFS_MAX_ID][NR_CL];
static struct freq_qos_request max_req[DVFS_MAX_ID][NR_CL];
static struct cpufreq_policy *cl_policy[NR_CL];
static struct kobject *cpufreq_kobj;

static bool limit_ready;
static int ltl_max_freq_div;
static int last_min_req_val = -1;
static int last_max_req_val = -1;
static DEFINE_MUTEX(cpufreq_limit_mutex);

static struct cpufreq_limit_parameter param = {
	.num_cpu		= 8,
	.freq_count		= 0,
	.ltl_cpu_start		= 0,
	.big_cpu_start		= 6,
	.ltl_max_freq		= 0,
	.ltl_min_lock_freq	= 1150000,
	.big_max_lock_freq	= 800000,
	.ltl_divider		= 4,
	.over_limit		= 0,
};

/**
 * cpufreq_limit_unify_table - make virtual table for limit driver
 *
 * Big frequencies as-is, then little frequencies divided by ltl_divider,
 * in each policy's own table order (Samsung's layout).
 */
static void cpufreq_limit_unify_table(void)
{
	struct cpufreq_frequency_table *pos;
	unsigned int n = 0, ltl_max = 0;

	cpufreq_for_each_valid_entry(pos, cl_policy[CL_BIG]->freq_table) {
		if (n >= CPUFREQ_LIMIT_TSIZE)
			break;
		param.unified_table[n++] = pos->frequency;
	}

	cpufreq_for_each_valid_entry(pos, cl_policy[CL_LTL]->freq_table) {
		if (n >= CPUFREQ_LIMIT_TSIZE)
			break;
		if (ltl_max < pos->frequency)
			ltl_max = pos->frequency;
		param.unified_table[n++] = pos->frequency / param.ltl_divider;
	}

	param.ltl_max_freq = ltl_max;
	param.freq_count = n;
	ltl_max_freq_div = ltl_max / param.ltl_divider;
}

static void req_update(struct freq_qos_request *req, s32 val)
{
	if (freq_qos_request_active(req))
		freq_qos_update_request(req, val);
}

/* Caller holds cpufreq_limit_mutex. */
static void cpufreq_limit_drop_requests(int cl)
{
	int id;

	for (id = 0; id < DVFS_MAX_ID; id++) {
		if (freq_qos_request_active(&min_req[id][cl]))
			freq_qos_remove_request(&min_req[id][cl]);
		if (freq_qos_request_active(&max_req[id][cl]))
			freq_qos_remove_request(&max_req[id][cl]);
	}
}

/* Caller holds cpufreq_limit_mutex. */
static int cpufreq_limit_add_requests(int cl)
{
	struct cpufreq_policy *policy = cl_policy[cl];
	int id, ret;

	for (id = 0; id < DVFS_MAX_ID; id++) {
		ret = freq_qos_add_request(&policy->constraints, &min_req[id][cl],
					   FREQ_QOS_MIN, FREQ_QOS_MIN_DEFAULT_VALUE);
		if (ret < 0)
			goto fail;
		ret = freq_qos_add_request(&policy->constraints, &max_req[id][cl],
					   FREQ_QOS_MAX, FREQ_QOS_MAX_DEFAULT_VALUE);
		if (ret < 0)
			goto fail;
	}
	return 0;
fail:
	pr_err("cluster %d: freq_qos_add_request failed %d\n", cl, ret);
	cpufreq_limit_drop_requests(cl);
	return ret;
}

/**
 * _set_freq_limit - core function to request frequencies
 * @id		request id
 * @min_freq	unified frequency for the min lock; -1 releases, 0 leaves as is
 * @max_freq	unified frequency for the max lock; -1 releases, 0 leaves as is
 */
static int _set_freq_limit(unsigned int id, int min_freq, int max_freq)
{
	if (id >= DVFS_MAX_ID)
		return -EINVAL;

	mutex_lock(&cpufreq_limit_mutex);
	if (!limit_ready) {
		mutex_unlock(&cpufreq_limit_mutex);
		return -EAGAIN;
	}

	if (min_freq == -1) {
		req_update(&min_req[id][CL_LTL], FREQ_QOS_MIN_DEFAULT_VALUE);
		req_update(&min_req[id][CL_BIG], FREQ_QOS_MIN_DEFAULT_VALUE);
	} else if (min_freq > 0) {
		if (min_freq > ltl_max_freq_div) {
			req_update(&min_req[id][CL_LTL], param.ltl_min_lock_freq);
			req_update(&min_req[id][CL_BIG], min_freq);
		} else {
			req_update(&min_req[id][CL_LTL], min_freq * param.ltl_divider);
			req_update(&min_req[id][CL_BIG], FREQ_QOS_MIN_DEFAULT_VALUE);
		}
	}

	if (max_freq == -1) {
		req_update(&max_req[id][CL_LTL], FREQ_QOS_MAX_DEFAULT_VALUE);
		req_update(&max_req[id][CL_BIG], FREQ_QOS_MAX_DEFAULT_VALUE);
	} else if (max_freq > 0) {
		if (max_freq > ltl_max_freq_div) {
			req_update(&max_req[id][CL_LTL], FREQ_QOS_MAX_DEFAULT_VALUE);
			req_update(&max_req[id][CL_BIG], max_freq);
		} else {
			req_update(&max_req[id][CL_LTL], max_freq * param.ltl_divider);
			req_update(&max_req[id][CL_BIG], param.big_max_lock_freq);
		}
	}

	mutex_unlock(&cpufreq_limit_mutex);
	return 0;
}

/**
 * set_freq_limit - API provided for frequency min lock operation
 * @id		request id
 * @freq	unified frequency; (unsigned int)-1 releases
 */
int set_freq_limit(unsigned int id, unsigned int freq)
{
	return _set_freq_limit(id, (int)freq, 0);
}

/******************************/
/*  cpufreq policy tracking   */
/******************************/

static int cpufreq_limit_cluster_of(struct cpufreq_policy *policy)
{
	if (cpumask_test_cpu(param.ltl_cpu_start, policy->related_cpus))
		return CL_LTL;
	if (cpumask_test_cpu(param.big_cpu_start, policy->related_cpus))
		return CL_BIG;
	return -1;
}

static int cpufreq_limit_policy_notifier(struct notifier_block *nb,
					 unsigned long event, void *data)
{
	struct cpufreq_policy *policy = data;
	int cl = cpufreq_limit_cluster_of(policy);

	if (cl < 0)
		return NOTIFY_DONE;

	mutex_lock(&cpufreq_limit_mutex);
	if (event == CPUFREQ_CREATE_POLICY && !cl_policy[cl]) {
		cl_policy[cl] = policy;
		if (cpufreq_limit_add_requests(cl) < 0) {
			cl_policy[cl] = NULL;
		} else if (cl_policy[CL_LTL] && cl_policy[CL_BIG]) {
			cpufreq_limit_unify_table();
			last_min_req_val = -1;
			last_max_req_val = -1;
			limit_ready = true;
			pr_info("ready: %u unified frequencies, split at %d\n",
				param.freq_count, ltl_max_freq_div);
		}
	} else if (event == CPUFREQ_REMOVE_POLICY && cl_policy[cl] == policy) {
		limit_ready = false;
		cpufreq_limit_drop_requests(cl);
		cl_policy[cl] = NULL;
		pr_info("cluster %d policy removed\n", cl);
	}
	mutex_unlock(&cpufreq_limit_mutex);

	return NOTIFY_OK;
}

static struct notifier_block cpufreq_limit_nb = {
	.notifier_call = cpufreq_limit_policy_notifier,
};

static void __init cpufreq_limit_adopt_existing(unsigned int cpu)
{
	struct cpufreq_policy *policy = cpufreq_cpu_get(cpu);

	if (!policy)
		return;
	cpufreq_limit_policy_notifier(&cpufreq_limit_nb, CPUFREQ_CREATE_POLICY,
				      policy);
	cpufreq_cpu_put(policy);
}

/******************************/
/*  Kernel object functions   */
/******************************/

#define cpufreq_limit_attr(_name)				\
static struct kobj_attribute _name##_attr = {			\
	.attr	= { .name = __stringify(_name), .mode = 0644 },	\
	.show	= _name##_show,					\
	.store	= _name##_store,				\
}

#define cpufreq_limit_attr_ro(_name)				\
static struct kobj_attribute _name##_attr = {			\
	.attr	= { .name = __stringify(_name), .mode = 0444 },	\
	.show	= _name##_show,					\
}

static ssize_t cpufreq_table_show(struct kobject *kobj,
				  struct kobj_attribute *attr, char *buf)
{
	ssize_t len = 0;
	unsigned int i;

	mutex_lock(&cpufreq_limit_mutex);
	for (i = 0; i < param.freq_count; i++)
		len += scnprintf(buf + len, MAX_BUF_SIZE - len, "%u ",
				 param.unified_table[i]);
	mutex_unlock(&cpufreq_limit_mutex);

	if (!len)
		return 0;
	buf[len - 1] = '\n';
	return len;
}

static ssize_t cpufreq_max_limit_show(struct kobject *kobj,
				      struct kobj_attribute *attr, char *buf)
{
	return sprintf(buf, "%d\n", last_max_req_val);
}

static ssize_t cpufreq_max_limit_store(struct kobject *kobj,
				       struct kobj_attribute *attr,
				       const char *buf, size_t count)
{
	int val, ret;

	if (sscanf(buf, "%d", &val) != 1)
		return -EINVAL;

	ret = _set_freq_limit(DVFS_USER_ID, 0, val);
	if (ret)
		return ret;
	last_max_req_val = val;
	return count;
}

static ssize_t cpufreq_min_limit_show(struct kobject *kobj,
				      struct kobj_attribute *attr, char *buf)
{
	return sprintf(buf, "%d\n", last_min_req_val);
}

static ssize_t cpufreq_min_limit_store(struct kobject *kobj,
				       struct kobj_attribute *attr,
				       const char *buf, size_t count)
{
	int val, ret;

	if (sscanf(buf, "%d", &val) != 1)
		return -EINVAL;

	ret = _set_freq_limit(DVFS_USER_ID, val, 0);
	if (ret)
		return ret;
	last_min_req_val = val;
	return count;
}

static ssize_t over_limit_show(struct kobject *kobj,
			       struct kobj_attribute *attr, char *buf)
{
	return sprintf(buf, "%d\n", param.over_limit);
}

static ssize_t over_limit_store(struct kobject *kobj,
				struct kobj_attribute *attr,
				const char *buf, size_t count)
{
	int val, ret;

	ret = kstrtoint(buf, 10, &val);
	if (ret < 0)
		return ret;

	ret = _set_freq_limit(DVFS_OVERLIMIT_ID, 0, val);
	if (ret)
		return ret;
	param.over_limit = (unsigned int)val;
	return count;
}

cpufreq_limit_attr_ro(cpufreq_table);
cpufreq_limit_attr(cpufreq_max_limit);
cpufreq_limit_attr(cpufreq_min_limit);
cpufreq_limit_attr(over_limit);

static struct attribute *cpufreq_limit_attr_g[] = {
	&cpufreq_table_attr.attr,
	&cpufreq_max_limit_attr.attr,
	&cpufreq_min_limit_attr.attr,
	&over_limit_attr.attr,
	NULL,
};

static const struct attribute_group cpufreq_limit_attr_group = {
	.attrs = cpufreq_limit_attr_g,
};

#define show_one(_name, object)						\
static ssize_t _name##_show						\
	(struct kobject *kobj, struct kobj_attribute *attr, char *buf)	\
{									\
	return sprintf(buf, "%u\n", param.object);			\
}

#define store_one(_name, object)					\
static ssize_t _name##_store						\
	(struct kobject *kobj, struct kobj_attribute *attr,		\
	 const char *buf, size_t count)					\
{									\
	unsigned int val;						\
									\
	if (kstrtouint(buf, 10, &val) || !val)				\
		return -EINVAL;						\
	mutex_lock(&cpufreq_limit_mutex);				\
	param.object = val;						\
	if (param.ltl_divider)						\
		ltl_max_freq_div = param.ltl_max_freq / param.ltl_divider; \
	mutex_unlock(&cpufreq_limit_mutex);				\
	return count;							\
}

show_one(ltl_cpu_start, ltl_cpu_start);
show_one(big_cpu_start, big_cpu_start);
show_one(ltl_max_freq, ltl_max_freq);
show_one(ltl_min_lock_freq, ltl_min_lock_freq);
show_one(big_max_lock_freq, big_max_lock_freq);
show_one(ltl_divider, ltl_divider);
store_one(ltl_max_freq, ltl_max_freq);
store_one(ltl_min_lock_freq, ltl_min_lock_freq);
store_one(big_max_lock_freq, big_max_lock_freq);
store_one(ltl_divider, ltl_divider);

cpufreq_limit_attr_ro(ltl_cpu_start);
cpufreq_limit_attr_ro(big_cpu_start);
cpufreq_limit_attr(ltl_max_freq);
cpufreq_limit_attr(ltl_min_lock_freq);
cpufreq_limit_attr(big_max_lock_freq);
cpufreq_limit_attr(ltl_divider);

static struct attribute *limit_param_attributes[] = {
	&ltl_cpu_start_attr.attr,
	&big_cpu_start_attr.attr,
	&ltl_max_freq_attr.attr,
	&ltl_min_lock_freq_attr.attr,
	&big_max_lock_freq_attr.attr,
	&ltl_divider_attr.attr,
	NULL,
};

static const struct attribute_group limit_param_attr_group = {
	.attrs = limit_param_attributes,
	.name = "parameters",
};

static int __init cpufreq_limit_init(void)
{
	int ret;

	cpufreq_kobj = kobject_create_and_add("cpufreq_limit",
					      &cpu_subsys.dev_root->kobj);
	if (!cpufreq_kobj)
		return -ENOMEM;

	ret = sysfs_create_group(cpufreq_kobj, &cpufreq_limit_attr_group);
	if (!ret)
		ret = sysfs_create_group(cpufreq_kobj, &limit_param_attr_group);
	if (ret) {
		pr_err("sysfs group creation failed %d\n", ret);
		kobject_put(cpufreq_kobj);
		cpufreq_kobj = NULL;
		return ret;
	}

	/*
	 * The MediaTek cpufreq driver is a vendor module loaded by first-stage
	 * init, after every initcall: its policies are reported to the notifier.
	 */
	ret = cpufreq_register_notifier(&cpufreq_limit_nb, CPUFREQ_POLICY_NOTIFIER);
	if (ret) {
		pr_err("policy notifier registration failed %d\n", ret);
		return ret;
	}

	/* A built-in cpufreq driver would have created them already. */
	cpufreq_limit_adopt_existing(param.ltl_cpu_start);
	cpufreq_limit_adopt_existing(param.big_cpu_start);
	return 0;
}
late_initcall(cpufreq_limit_init);
