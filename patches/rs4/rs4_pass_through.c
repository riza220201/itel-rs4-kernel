// SPDX-License-Identifier: GPL-2.0
/*
 * rs4_pass_through - Samsung's battery "pass_through" node on the itel RS4
 *
 * One UI's Game Booster offers "Pause USB PD charging when gaming": while a
 * game runs it sets Settings.System pass_through=1 and Samsung's
 * BatteryService writes "1" to /sys/class/power_supply/battery/pass_through,
 * a sec_battery node the itel kernel does not have ("fail to set PassThrough
 * sysfs"). This driver provides that node on the itel battery power supply
 * and maps it to the charger bypass itel already ships:
 *
 *     /sys/devices/platform/charger/tran_aichg_disable_charger  (1 = bypass)
 *
 * Measured on this hardware (crDroid GameSpace fork, BYPASS-CHARGING-PROOF):
 * with bypass on, battery current falls from about +400 mA to about 0 mA
 * while the adapter carries the system load -- a true bypass, not merely
 * "charging stopped".
 *
 * A write is a REQUEST. Bypass is only engaged while the charger is online
 * and the battery is at or above min_capacity (Samsung's own rule is "the
 * battery is over 20%"), and it is released below release_capacity or when
 * the charger goes away, then re-engaged if the request still stands. Nothing
 * persists across a reboot: the itel node itself resets to 0 at boot.
 *
 * The itel attribute's own store handler is called directly (looked up
 * through its sysfs node), so no file I/O, DAC or SELinux path is involved
 * on the kernel side. The new node is owned by system:system like Samsung's
 * sec_battery nodes, because BatteryService (system_server) writes it.
 *
 * KMI: a new self-contained built-in driver; no struct or existing-symbol
 * change.
 */

#define pr_fmt(fmt) "rs4_pass_through: " fmt

#include <linux/device.h>
#include <linux/init.h>
#include <linux/kernfs.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/power_supply.h>
#include <linux/sysfs.h>
#include <linux/uidgid.h>
#include <linux/workqueue.h>

#define ITEL_CHARGER_DEV	"charger"
#define ITEL_BYPASS_ATTR	"tran_aichg_disable_charger"
#define AID_SYSTEM		1000

static unsigned int min_capacity = 20;
module_param(min_capacity, uint, 0644);
MODULE_PARM_DESC(min_capacity, "engage bypass only at or above this battery %");

static unsigned int release_capacity = 15;
module_param(release_capacity, uint, 0644);
MODULE_PARM_DESC(release_capacity, "release bypass below this battery %");

static DEFINE_MUTEX(pt_lock);
static struct power_supply *bat_psy;
static bool pt_requested;
static bool pt_active;

module_param_named(active, pt_active, bool, 0444);
module_param_named(requested, pt_requested, bool, 0444);

static int itel_bypass_write(bool on)
{
	struct device_attribute *dattr;
	struct kernfs_node *kn;
	struct device *dev;
	ssize_t ret = -ENOENT;

	dev = bus_find_device_by_name(&platform_bus_type, NULL, ITEL_CHARGER_DEV);
	if (!dev)
		return -ENODEV;

	kn = dev->kobj.sd ? kernfs_find_and_get(dev->kobj.sd, ITEL_BYPASS_ATTR) : NULL;
	if (kn) {
		dattr = container_of((struct attribute *)kn->priv,
				     struct device_attribute, attr);
		ret = dattr->store ? dattr->store(dev, dattr, on ? "1\n" : "0\n", 2)
				   : -EPERM;
		kernfs_put(kn);
	}
	put_device(dev);

	return ret < 0 ? (int)ret : 0;
}

static bool charger_online(void)
{
	struct power_supply *chg = power_supply_get_by_name(ITEL_CHARGER_DEV);
	union power_supply_propval val = { 0 };
	bool online = false;

	if (!chg)
		return false;
	if (!power_supply_get_property(chg, POWER_SUPPLY_PROP_ONLINE, &val))
		online = val.intval > 0;
	power_supply_put(chg);
	return online;
}

static int battery_capacity(void)
{
	union power_supply_propval val = { 0 };

	if (!bat_psy ||
	    power_supply_get_property(bat_psy, POWER_SUPPLY_PROP_CAPACITY, &val))
		return -1;
	return val.intval;
}

/* Caller holds pt_lock. */
static void pt_evaluate(void)
{
	int cap;
	bool want;
	int ret;

	/* The common case on every battery event: nothing asked, nothing on. */
	if (!pt_requested && !pt_active)
		return;

	cap = battery_capacity();
	want = pt_requested && charger_online() && cap >= 0 &&
	       cap >= (int)(pt_active ? release_capacity : min_capacity);
	if (want == pt_active)
		return;

	ret = itel_bypass_write(want);
	if (ret) {
		pr_err("setting itel bypass to %d failed: %d\n", want, ret);
		return;
	}
	pt_active = want;
	pr_info("bypass %s (requested %d, battery %d%%)\n",
		want ? "ENGAGED" : "released", pt_requested, cap);
}

static ssize_t pass_through_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	return sprintf(buf, "%d\n", pt_active);
}

static ssize_t pass_through_store(struct device *dev,
				  struct device_attribute *attr,
				  const char *buf, size_t count)
{
	int val;

	if (kstrtoint(buf, 10, &val))
		return -EINVAL;

	mutex_lock(&pt_lock);
	pt_requested = val != 0;
	pt_evaluate();
	mutex_unlock(&pt_lock);

	return count;
}
static DEVICE_ATTR_RW(pass_through);

/* ---- attach to the battery power supply, follow its changes -------------- */

static void pt_work_fn(struct work_struct *work);
static DECLARE_DELAYED_WORK(pt_work, pt_work_fn);
static unsigned int attach_tries;

static void pt_work_fn(struct work_struct *work)
{
	int ret;

	mutex_lock(&pt_lock);
	if (!bat_psy) {
		bat_psy = power_supply_get_by_name("battery");
		if (!bat_psy) {
			mutex_unlock(&pt_lock);
			/* The gauge is a vendor module; keep looking for 3 min. */
			if (++attach_tries < 180)
				queue_delayed_work(system_power_efficient_wq,
						   &pt_work, HZ);
			return;
		}
		ret = device_create_file(&bat_psy->dev, &dev_attr_pass_through);
		if (ret) {
			pr_err("creating battery/pass_through failed %d\n", ret);
		} else {
			ret = sysfs_file_change_owner(&bat_psy->dev.kobj, "pass_through",
						      KUIDT_INIT(AID_SYSTEM),
						      KGIDT_INIT(AID_SYSTEM));
			if (ret)
				pr_err("chown battery/pass_through failed %d\n", ret);
			pr_info("battery/pass_through ready\n");
		}
	}
	pt_evaluate();
	mutex_unlock(&pt_lock);
}

static int pt_psy_notifier(struct notifier_block *nb, unsigned long event,
			   void *data)
{
	struct power_supply *psy = data;

	if (event != PSY_EVENT_PROP_CHANGED || !psy->desc || !psy->desc->name)
		return NOTIFY_DONE;
	if (strcmp(psy->desc->name, "battery") &&
	    strcmp(psy->desc->name, ITEL_CHARGER_DEV))
		return NOTIFY_DONE;

	/* Atomic notifier chain: do the work where sleeping is allowed. */
	mod_delayed_work(system_power_efficient_wq, &pt_work, 0);
	return NOTIFY_OK;
}

static struct notifier_block pt_psy_nb = {
	.notifier_call = pt_psy_notifier,
};

static int __init rs4_pass_through_init(void)
{
	int ret = power_supply_reg_notifier(&pt_psy_nb);

	if (ret) {
		pr_err("power supply notifier registration failed %d\n", ret);
		return ret;
	}
	queue_delayed_work(system_power_efficient_wq, &pt_work, 0);
	return 0;
}
late_initcall(rs4_pass_through_init);
