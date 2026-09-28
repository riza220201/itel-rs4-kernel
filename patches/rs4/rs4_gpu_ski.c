// SPDX-License-Identifier: GPL-2.0
/*
 * rs4_gpu_ski - Samsung's /sys/kernel/gpu interface on the itel RS4 (MT6789)
 *
 * Samsung's MediaTek kernels create /sys/kernel/gpu from the GED module
 * ("SKI", drivers/gpu/mediatek/ged/src/ged_ski.c in the Galaxy A17 4G
 * source). One UI's Game Optimizing Service reads it first when it sets up
 * GPU monitoring (gpu_busy, gpu_clock, gpu_freq_table, gpu_max_clock,
 * gpu_min_clock). itel's GED is a stock prebuilt module without SKI, so this
 * built-in shim provides the same files, in Samsung's formats, from the
 * helpers itel's own modules export:
 *
 *   mtk_gpu_hal.ko           mtk_get_gpu_loading, mtk_get_gpu_ceiling_index,
 *                            mtk_get_gpu_bottom_freq,
 *                            mtk_custom_upbound_gpu_freq, mtk_custom_boost_gpu_freq
 *   mtk_gpufreq_wrapper.ko   gpufreq_get_cur_freq, gpufreq_get_cur_volt,
 *                            gpufreq_get_opp_num, gpufreq_get_freq_by_idx
 *
 * They are resolved on first use, because the modules load after every
 * initcall -- NOT with symbol_get(): this kernel carries the upstream backport
 * "module: Only allow GPL-only symbols via symbol_get", and MediaTek exports
 * these with plain EXPORT_SYMBOL, so symbol_get() refuses every one of them
 * ("failing symbol_get of non-GPLONLY symbol", measured on 5.10.268). The
 * lookup below finds the owner module under module_mutex, takes a reference,
 * and resolves each helper's CFI jump-table entry from that module's kallsyms
 * (see rs4_module_symbol() for why it must not be the export-table value).
 * Differences from Samsung's SKI, both because itel's
 * modules do not export the Samsung-side helper:
 *   gpu_busy      instantaneous loading (Samsung shows the moving average)
 *   gpu_max_clock / gpu_min_clock   the custom limits written through this
 *                 interface are remembered here (no getter is exported)
 *
 * 🔴 CFI: every call below is an indirect call into a module, checked by
 * __cfi_slowpath against the owner's __cfi_check with the declared prototype's
 * type id. They are MediaTek's 5.10 declarations verbatim (mtk_gpu_utility.h,
 * gpufreq_v2.h), including enum gpufreq_target, whose NAME is part of the CFI
 * type. All seven type ids were matched against the ranges mtk_gpu_hal.ko's and
 * mtk_gpufreq_wrapper.ko's __cfi_check accept (2026-09-28). Change none of them.
 *
 * KMI: a new self-contained built-in driver; no struct or existing-symbol
 * change.
 */

#define pr_fmt(fmt) "rs4_gpu_ski: " fmt

#include <linux/init.h>
#include <linux/kallsyms.h>
#include <linux/kernel.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/sysfs.h>

/* ---- MediaTek 5.10 declarations, verbatim (see the CFI note) ------------- */

enum gpufreq_target {
	TARGET_DEFAULT = 0,
	TARGET_GPU = 1,
	TARGET_STACK,
	TARGET_INVALID,
};

extern bool mtk_get_gpu_loading(unsigned int *pLoading);
extern bool mtk_custom_boost_gpu_freq(unsigned int ui32FreqLevel);
extern bool mtk_custom_upbound_gpu_freq(unsigned int ui32FreqLevel);
extern bool mtk_get_gpu_bottom_freq(unsigned long *pulFreq);
extern bool mtk_get_gpu_ceiling_index(int *piIndex);
extern unsigned int gpufreq_get_cur_freq(enum gpufreq_target target);
extern unsigned int gpufreq_get_cur_volt(enum gpufreq_target target);
extern int gpufreq_get_opp_num(enum gpufreq_target target);
extern unsigned int gpufreq_get_freq_by_idx(enum gpufreq_target target, int oppidx);

/* ---- lazily resolved module helpers ---------------------------------------- */

static DEFINE_MUTEX(ski_lock);
static bool ski_resolved;

static typeof(&mtk_get_gpu_loading)		p_get_loading;
static typeof(&mtk_custom_boost_gpu_freq)	p_custom_boost;
static typeof(&mtk_custom_upbound_gpu_freq)	p_custom_upbound;
static typeof(&mtk_get_gpu_bottom_freq)		p_get_bottom;
static typeof(&mtk_get_gpu_ceiling_index)	p_get_ceiling;
static typeof(&gpufreq_get_cur_freq)		p_cur_freq;
static typeof(&gpufreq_get_cur_volt)		p_cur_volt;
static typeof(&gpufreq_get_opp_num)		p_opp_num;
static typeof(&gpufreq_get_freq_by_idx)		p_freq_by_idx;

/* Limits set through gpu_max_clock / gpu_min_clock (0 = none). */
static unsigned int custom_max_khz;
static unsigned int custom_min_khz;

#define HAL	"mtk_gpu_hal"
#define GPUFREQ	"mtk_gpufreq_wrapper"

/*
 * A callable address for @name in module @modname, with a reference held on
 * that module; NULL if it is not loaded (yet).
 *
 * 🔴 NOT the export-table value. With -fno-sanitize-cfi-canonical-jump-tables
 * a ksymtab entry points at the function BODY (include/linux/export.h emits it
 * in asm on purpose), while the owner's __cfi_check accepts only its own
 * "<name>.cfi_jt" jump-table entries. v7 called the bodies: the first read of
 * a value node (GOS's IPM, right after BOOT_COMPLETED) died in
 * __cfi_check_fail -> panic("CFI failure"), which mrdump turned into a PMIC
 * cold reset about 35 s into every boot. The .cfi_jt entry is what a module
 * linked against the export gets from its own jump table, and it keeps the
 * call type-checked against the owner.
 */
static void *rs4_module_symbol(const char *modname, const char *name)
{
	char full[MODULE_NAME_LEN + KSYM_NAME_LEN];
	struct module *mod;
	void *addr = NULL;

	snprintf(full, sizeof(full), IS_ENABLED(CONFIG_CFI_CLANG) ?
		 "%s:%s.cfi_jt" : "%s:%s", modname, name);

	mutex_lock(&module_mutex);
	mod = find_module(modname);
	if (mod && mod->state == MODULE_STATE_LIVE && try_module_get(mod)) {
		addr = (void *)module_kallsyms_lookup_name(full);
		if (!addr)
			module_put(mod);
	}
	mutex_unlock(&module_mutex);
	return addr;
}

#define RESOLVE(p, owner, sym) \
	do { if (!(p)) (p) = (typeof(p))rs4_module_symbol(owner, #sym); } while (0)

/* Returns true once every helper is available. Modules never unload here. */
static bool ski_resolve(void)
{
	if (READ_ONCE(ski_resolved))
		return true;

	mutex_lock(&ski_lock);
	RESOLVE(p_get_loading, HAL, mtk_get_gpu_loading);
	RESOLVE(p_custom_boost, HAL, mtk_custom_boost_gpu_freq);
	RESOLVE(p_custom_upbound, HAL, mtk_custom_upbound_gpu_freq);
	RESOLVE(p_get_bottom, HAL, mtk_get_gpu_bottom_freq);
	RESOLVE(p_get_ceiling, HAL, mtk_get_gpu_ceiling_index);
	RESOLVE(p_cur_freq, GPUFREQ, gpufreq_get_cur_freq);
	RESOLVE(p_cur_volt, GPUFREQ, gpufreq_get_cur_volt);
	RESOLVE(p_opp_num, GPUFREQ, gpufreq_get_opp_num);
	RESOLVE(p_freq_by_idx, GPUFREQ, gpufreq_get_freq_by_idx);
	if (p_get_loading && p_custom_boost && p_custom_upbound && p_get_bottom &&
	    p_get_ceiling && p_cur_freq && p_cur_volt && p_opp_num && p_freq_by_idx) {
		WRITE_ONCE(ski_resolved, true);
		pr_info("GED/gpufreq helpers resolved, %d OPPs\n",
			p_opp_num(TARGET_DEFAULT));
	}
	mutex_unlock(&ski_lock);

	return READ_ONCE(ski_resolved);
}

/* OPP index of an exact table frequency, or -1. */
static int ski_freq_to_idx(unsigned int khz)
{
	int n = p_opp_num(TARGET_DEFAULT), i;

	for (i = 0; i < n; i++)
		if (p_freq_by_idx(TARGET_DEFAULT, i) == khz)
			return i;
	return -1;
}

/* ---- attributes, Samsung SKI formats ---------------------------------------- */

static ssize_t gpu_available_governor_show(struct kobject *kobj,
					   struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "Default\n");
}

static ssize_t gpu_governor_show(struct kobject *kobj,
				 struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "Default\n");
}

static ssize_t gpu_model_show(struct kobject *kobj,
			      struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "Mali-G57 MC2\n");
}

static ssize_t gpu_busy_show(struct kobject *kobj,
			     struct kobj_attribute *attr, char *buf)
{
	unsigned int loading = 0;

	if (!ski_resolve())
		return -EAGAIN;
	p_get_loading(&loading);
	return scnprintf(buf, PAGE_SIZE, "%u %%\n", loading);
}

static ssize_t gpu_clock_show(struct kobject *kobj,
			      struct kobj_attribute *attr, char *buf)
{
	unsigned int khz;

	if (!ski_resolve())
		return -EAGAIN;
	/* Samsung reports 0 while the GPU is powered off (no voltage). */
	khz = p_cur_volt(TARGET_DEFAULT) ? p_cur_freq(TARGET_DEFAULT) : 0;
	return scnprintf(buf, PAGE_SIZE, "%u\n", khz);
}

static ssize_t gpu_freq_table_show(struct kobject *kobj,
				   struct kobj_attribute *attr, char *buf)
{
	ssize_t len = 0;
	int n, i;

	if (!ski_resolve())
		return -EAGAIN;
	n = p_opp_num(TARGET_DEFAULT);
	for (i = 0; i < n; i++)
		len += scnprintf(buf + len, PAGE_SIZE - len, "%u ",
				 p_freq_by_idx(TARGET_DEFAULT, i));
	len += scnprintf(buf + len, PAGE_SIZE - len, "\n");
	return len;
}

static ssize_t gpu_max_clock_show(struct kobject *kobj,
				  struct kobj_attribute *attr, char *buf)
{
	unsigned int khz;
	int idx = 0;

	if (!ski_resolve())
		return -EAGAIN;
	p_get_ceiling(&idx);
	khz = p_freq_by_idx(TARGET_DEFAULT, idx);
	if (custom_max_khz && custom_max_khz < khz)
		khz = custom_max_khz;
	return scnprintf(buf, PAGE_SIZE, "%u\n", khz);
}

static ssize_t gpu_max_clock_store(struct kobject *kobj,
				   struct kobj_attribute *attr,
				   const char *buf, size_t count)
{
	unsigned int khz;
	int idx;

	if (kstrtouint(buf, 0, &khz) || !khz)
		return -EINVAL;
	if (!ski_resolve())
		return -EAGAIN;
	idx = ski_freq_to_idx(khz);
	if (idx < 0)
		return -EINVAL;
	p_custom_upbound(idx);
	custom_max_khz = idx ? khz : 0;	/* OPP 0 is the top: no limit */
	return count;
}

static ssize_t gpu_min_clock_show(struct kobject *kobj,
				  struct kobj_attribute *attr, char *buf)
{
	unsigned long khz = 0;

	if (!ski_resolve())
		return -EAGAIN;
	p_get_bottom(&khz);
	if (custom_min_khz > khz)
		khz = custom_min_khz;
	return scnprintf(buf, PAGE_SIZE, "%lu\n", khz);
}

static ssize_t gpu_min_clock_store(struct kobject *kobj,
				   struct kobj_attribute *attr,
				   const char *buf, size_t count)
{
	unsigned int khz;
	int idx, n;

	if (kstrtouint(buf, 0, &khz) || !khz)
		return -EINVAL;
	if (!ski_resolve())
		return -EAGAIN;
	idx = ski_freq_to_idx(khz);
	if (idx < 0)
		return -EINVAL;
	p_custom_boost(idx);
	n = p_opp_num(TARGET_DEFAULT);
	custom_min_khz = (idx == n - 1) ? 0 : khz;	/* last OPP is the floor */
	return count;
}

static struct kobj_attribute gpu_attrs[] = {
	__ATTR_RO(gpu_available_governor),
	__ATTR_RO(gpu_busy),
	__ATTR_RO(gpu_clock),
	__ATTR_RO(gpu_freq_table),
	__ATTR_RO(gpu_governor),
	__ATTR(gpu_max_clock, 0644, gpu_max_clock_show, gpu_max_clock_store),
	__ATTR(gpu_min_clock, 0644, gpu_min_clock_show, gpu_min_clock_store),
	__ATTR_RO(gpu_model),
};

static struct attribute *gpu_attr_ptrs[ARRAY_SIZE(gpu_attrs) + 1];

static const struct attribute_group gpu_attr_group = {
	.attrs = gpu_attr_ptrs,
};

static int __init rs4_gpu_ski_init(void)
{
	struct kobject *kobj;
	int i, ret;

	for (i = 0; i < ARRAY_SIZE(gpu_attrs); i++)
		gpu_attr_ptrs[i] = &gpu_attrs[i].attr;

	kobj = kobject_create_and_add("gpu", kernel_kobj);
	if (!kobj)
		return -ENOMEM;
	ret = sysfs_create_group(kobj, &gpu_attr_group);
	if (ret) {
		pr_err("sysfs group creation failed %d\n", ret);
		kobject_put(kobj);
	}
	return ret;
}
late_initcall(rs4_gpu_ski_init);
