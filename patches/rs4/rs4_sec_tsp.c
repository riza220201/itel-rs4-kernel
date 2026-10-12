// SPDX-License-Identifier: GPL-2.0
/*
 * rs4_sec_tsp - Samsung's /sys/class/sec/tsp on the itel RS4, for double-tap-to-wake
 *
 * One UI drives a Samsung touchscreen through secinputdev-service.jar. With no
 * Samsung sysinput HAL (this device has none) it falls back to plain sysfs
 * (SysinputHALEmpty):
 *
 *   /sys/class/sec/tsp/support_feature  read, Integer.parseInt: bit 0 = AOT
 *                                       (double tap to wake). InputManager
 *                                       .semCheckInputFeature() & 1 decides
 *                                       PhoneWindowManagerExt
 *                                       .mIsDoubleTapToWakeUpSupported.
 *   /sys/class/sec/tsp/cmd_list         read: the commands the panel accepts
 *   /sys/class/sec/tsp/cmd              write "aot_enable,1" / "aot_enable,0",
 *                                       from the "Double tap to turn on
 *                                       screen" setting (and at boot)
 *
 * The itel panel is a FocalTech FT8057S behind Transsion's touch core
 * (adaptive_ts.ko). Its double-tap gesture is entry "cc" of gesture_maps;
 * writing "cc1"/"cc2" to /proc/gesture_function sets gesturedouble_enabled and
 * that entry's enabled byte, nothing else -- read out of gesture_data_write()
 * (adaptive-ts.ko md5 86e94081). The core then arms the chip at suspend and
 * reports a detected double tap as KEY_F13, which the ROM's
 * /vendor/usr/keylayout/mtk-tpd.kl maps to WAKEUP (proven on hardware,
 * PowerManagerService "reason=wake_key ... KEY(224)", 2026-10-12).
 *
 * This shim creates the Samsung nodes and turns "aot_enable,N" into the same
 * two stores. /sys/class/sec belongs to MediaTek's "sec" module (a static
 * sec_class), so both modules are resolved from their kallsyms when they go
 * live -- data symbols only, no calls into either module. Every value is
 * validated first (the class name, the "cc" record's name, code and group);
 * on any mismatch the feature reports unsupported and nothing is written.
 *
 * KMI: a new self-contained built-in driver; no struct or existing-symbol change.
 */

#define pr_fmt(fmt) "rs4_sec_tsp: " fmt

#include <linux/device.h>
#include <linux/init.h>
#include <linux/kallsyms.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/notifier.h>
#include <linux/string.h>
#include <linux/sysfs.h>

#define SEC_MOD		"sec"
#define TS_MOD		"adaptive_ts"

/* adaptive_ts gesture_maps record: name[2] pad enabled code ... group(u32 @8) */
#define GM_STRIDE	12
#define GM_CC_INDEX	1
#define GM_OFF_ENABLED	3
#define GM_OFF_CODE	4
#define GM_OFF_GROUP	8
#define GM_CC_CODE	0xcc

static DEFINE_MUTEX(tsp_lock);
static struct device *tsp_dev;
static int *p_dbl_enabled;	/* adaptive_ts:gesturedouble_enabled */
static u8 *p_cc;		/* &adaptive_ts:gesture_maps[GM_CC_INDEX] */
static int aot_wanted = -1;	/* last aot_enable value; -1 = never written */
static const char *cmd_status = "WAITING";
static char cmd_result[64];

/* Address of a DATA symbol in a live module (no .cfi_jt: these are not called). */
static void *mod_data(const char *modname, const char *name)
{
	char full[MODULE_NAME_LEN + KSYM_NAME_LEN];
	struct module *mod;
	void *addr = NULL;

	snprintf(full, sizeof(full), "%s:%s", modname, name);
	mutex_lock(&module_mutex);
	mod = find_module(modname);
	if (mod && mod->state == MODULE_STATE_LIVE)
		addr = (void *)module_kallsyms_lookup_name(full);
	mutex_unlock(&module_mutex);
	return addr;
}

static void aot_apply(int on)	/* tsp_lock held */
{
	WRITE_ONCE(*p_dbl_enabled, on);
	WRITE_ONCE(p_cc[GM_OFF_ENABLED], on ? 1 : 0);
	pr_info("double tap to wake %s\n", on ? "on" : "off");
}

/* ---- sysfs ----------------------------------------------------------------- */

static ssize_t cmd_store(struct device *dev, struct device_attribute *attr,
			 const char *buf, size_t count)
{
	char line[64], *param;
	int on;

	strscpy(line, buf, min(count + 1, sizeof(line)));
	strim(line);
	param = strchr(line, ',');
	if (param)
		*param++ = '\0';

	mutex_lock(&tsp_lock);
	if (!strcmp(line, "aot_enable") && param && !kstrtoint(param, 10, &on) &&
	    (on == 0 || on == 1)) {
		aot_wanted = on;
		if (p_cc)
			aot_apply(on);
		cmd_status = "OK";
		snprintf(cmd_result, sizeof(cmd_result), "%s:OK", line);
	} else {
		cmd_status = "NOT_APPLICABLE";
		snprintf(cmd_result, sizeof(cmd_result), "%s:NA", line);
	}
	mutex_unlock(&tsp_lock);
	return count;
}
static DEVICE_ATTR_WO(cmd);

static ssize_t cmd_status_show(struct device *dev, struct device_attribute *attr,
			       char *buf)
{
	return sysfs_emit(buf, "%s\n", READ_ONCE(cmd_status));
}
static DEVICE_ATTR_RO(cmd_status);

static ssize_t cmd_result_show(struct device *dev, struct device_attribute *attr,
			       char *buf)
{
	ssize_t n;

	mutex_lock(&tsp_lock);
	n = sysfs_emit(buf, "%s\n", cmd_result);
	mutex_unlock(&tsp_lock);
	return n;
}
static DEVICE_ATTR_RO(cmd_result);

static ssize_t cmd_list_show(struct device *dev, struct device_attribute *attr,
			     char *buf)
{
	return sysfs_emit(buf, "aot_enable\n");
}
static DEVICE_ATTR_RO(cmd_list);

static ssize_t support_feature_show(struct device *dev,
				    struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", READ_ONCE(p_cc) ? 1 : 0);	/* bit 0: AOT */
}
static DEVICE_ATTR_RO(support_feature);

static struct attribute *tsp_attrs[] = {
	&dev_attr_cmd.attr,
	&dev_attr_cmd_status.attr,
	&dev_attr_cmd_result.attr,
	&dev_attr_cmd_list.attr,
	&dev_attr_support_feature.attr,
	NULL,
};
ATTRIBUTE_GROUPS(tsp);

/* ---- module arrival -------------------------------------------------------- */

static void tsp_try_sec(void)	/* tsp_lock held */
{
	struct class **pcls, *cls;
	struct device *dev;

	if (tsp_dev)
		return;
	pcls = mod_data(SEC_MOD, "sec_class");
	if (!pcls)
		return;
	cls = READ_ONCE(*pcls);
	if (!cls || !cls->name || strcmp(cls->name, "sec")) {
		pr_err("sec:sec_class is not the \"sec\" class -- not creating tsp\n");
		return;
	}
	dev = device_create_with_groups(cls, NULL, MKDEV(0, 0), NULL, tsp_groups, "tsp");
	if (IS_ERR(dev)) {
		pr_err("device_create(sec/tsp) failed: %ld\n", PTR_ERR(dev));
		return;
	}
	tsp_dev = dev;
	pr_info("/sys/class/sec/tsp created\n");
}

static void tsp_try_ts(void)	/* tsp_lock held */
{
	int *dbl;
	u8 *maps, *cc;

	if (p_cc)
		return;
	dbl = mod_data(TS_MOD, "gesturedouble_enabled");
	maps = mod_data(TS_MOD, "gesture_maps");
	if (!dbl || !maps)
		return;
	cc = maps + GM_CC_INDEX * GM_STRIDE;
	if (cc[0] != 'c' || cc[1] != 'c' || cc[GM_OFF_CODE] != GM_CC_CODE ||
	    *(u32 *)(cc + GM_OFF_GROUP) != 0) {
		pr_err("adaptive_ts gesture_maps[%d] is not the \"cc\" double-tap record -- unsupported\n",
		       GM_CC_INDEX);
		return;
	}
	p_dbl_enabled = dbl;
	WRITE_ONCE(p_cc, cc);
	pr_info("adaptive_ts double-tap gesture resolved\n");
	if (aot_wanted >= 0)
		aot_apply(aot_wanted);
}

static int tsp_module_notify(struct notifier_block *nb, unsigned long action, void *data)
{
	struct module *mod = data;

	if (action != MODULE_STATE_LIVE)
		return NOTIFY_DONE;
	mutex_lock(&tsp_lock);
	if (!strcmp(mod->name, SEC_MOD))
		tsp_try_sec();
	else if (!strcmp(mod->name, TS_MOD))
		tsp_try_ts();
	mutex_unlock(&tsp_lock);
	return NOTIFY_DONE;
}

static struct notifier_block tsp_module_nb = {
	.notifier_call = tsp_module_notify,
};

static int __init rs4_sec_tsp_init(void)
{
	int ret = register_module_notifier(&tsp_module_nb);

	if (ret)
		return ret;
	/* Both are vendor_boot modules, which load after every initcall; this
	 * only matters if that ever changes. */
	mutex_lock(&tsp_lock);
	tsp_try_sec();
	tsp_try_ts();
	mutex_unlock(&tsp_lock);
	return 0;
}
late_initcall(rs4_sec_tsp_init);
