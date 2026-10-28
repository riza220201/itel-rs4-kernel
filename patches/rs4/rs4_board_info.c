// SPDX-License-Identifier: GPL-2.0
/*
 * rs4_board_info - vivo's /sys/board_info on the itel RS4, for About phone
 *
 * vivo's framework (framework-adapter com.vivo.adapter.cpuinfo.CpuInfoImpl, the
 * MTK flavour) reads two vivo kernel nodes when ro.vendor.build.version.release
 * <= 15 (our vendor reports 13; above 15 it reads /sys/cpu_info/ instead):
 *
 *   /sys/board_info/user_cpu_freq   first line, the displayed clock in GHz:
 *                                   Settings' VivoDeviceInfoCpuController
 *                                   .getCpuInfo() does Double.parseDouble() on
 *                                   it and prints it with one or more fraction
 *                                   digits before the core-count string
 *                                   ("2.2" -> "2.2 GHz Octa-core"). Absent, the
 *                                   page read "null GHz Octa-core".
 *   /sys/board_info/cpu_set         first line, "<family>_<model>": getCpuModel()
 *                                   splits it on "_" and maps the family
 *                                   ("Helio", "Dimensity", ...) to vivo's own
 *                                   string, then appends the model.
 *
 * Core count comes from /sys/devices/system/cpu/cpu[0-9] (already present).
 *
 * user_cpu_freq is computed at read time from cpufreq: the highest
 * cpuinfo.max_freq of any policy, in GHz with two decimals when the second is
 * not zero (RS4: 2200000 kHz -> "2.2"). CPU frequency on the MT6789 is owned by
 * the mcupm firmware and cpufreq reads its table, so an mcupm overclock
 * (big 2.2 -> 2.64 GHz) shows as "2.64" with no kernel or ROM change.
 * cpu_set is a parameter (rs4_board_info.cpu_set=), default "Helio_G99", the
 * RS4's MT6789.
 *
 * KMI: a new self-contained built-in driver; no struct or existing-symbol change.
 */

#define pr_fmt(fmt) "rs4_board_info: " fmt

#include <linux/cpufreq.h>
#include <linux/cpumask.h>
#include <linux/init.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/sysfs.h>

static char *cpu_set = "Helio_G99";
module_param(cpu_set, charp, 0444);
MODULE_PARM_DESC(cpu_set, "vivo /sys/board_info/cpu_set, \"<family>_<model>\"");

static struct kobject *board_info_kobj;

static ssize_t cpu_set_show(struct kobject *kobj, struct kobj_attribute *attr,
			    char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%s\n", cpu_set);
}

static ssize_t user_cpu_freq_show(struct kobject *kobj,
				  struct kobj_attribute *attr, char *buf)
{
	struct cpufreq_policy *policy;
	unsigned int khz = 0, cpu;

	for_each_possible_cpu(cpu) {
		policy = cpufreq_cpu_get(cpu);
		if (!policy)
			continue;
		khz = max(khz, policy->cpuinfo.max_freq);
		cpufreq_cpu_put(policy);
	}
	if (!khz)
		return -ENODATA;
	khz = (khz + 5000) / 10000;	/* hundredths of a GHz, rounded */
	if (khz % 10)
		return scnprintf(buf, PAGE_SIZE, "%u.%02u\n", khz / 100, khz % 100);
	return scnprintf(buf, PAGE_SIZE, "%u.%u\n", khz / 100, (khz / 10) % 10);
}

static struct kobj_attribute cpu_set_attr = __ATTR_RO(cpu_set);
static struct kobj_attribute user_cpu_freq_attr = __ATTR_RO(user_cpu_freq);

static struct attribute *board_info_attrs[] = {
	&cpu_set_attr.attr,
	&user_cpu_freq_attr.attr,
	NULL,
};

static const struct attribute_group board_info_group = {
	.attrs = board_info_attrs,
};

static int __init rs4_board_info_init(void)
{
	int ret;

	board_info_kobj = kobject_create_and_add("board_info", NULL);
	if (!board_info_kobj)
		return -ENOMEM;
	ret = sysfs_create_group(board_info_kobj, &board_info_group);
	if (ret) {
		kobject_put(board_info_kobj);
		return ret;
	}
	pr_info("/sys/board_info: cpu_set=%s\n", cpu_set);
	return 0;
}

static void __exit rs4_board_info_exit(void)
{
	sysfs_remove_group(board_info_kobj, &board_info_group);
	kobject_put(board_info_kobj);
}

late_initcall(rs4_board_info_init);
module_exit(rs4_board_info_exit);
MODULE_DESCRIPTION("vivo /sys/board_info (cpu_set, user_cpu_freq) for the itel RS4");
MODULE_LICENSE("GPL");
