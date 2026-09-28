// SPDX-License-Identifier: GPL-2.0
/*
 * rs4_balance - a balanced CPU frequency policy for the itel RS4 (MT6789)
 *
 * Three small behaviours, all expressed as freq_qos requests on the two
 * cpufreq policies, so the governor (reflex) keeps doing the real work and
 * thermal limits keep winning (a max request always beats a min request):
 *
 *  boot boost      full clock on both clusters until boot_boost_ms of uptime,
 *                  then released. Faster boot, no lasting cost.
 *  touch boost     a direct-touch event raises a modest floor through the
 *                  Samsung-compatible cpufreq_limit touch slot (DVFS_TOUCH_ID),
 *                  released touch_boost_ms after the last event. The default
 *                  (unified 300000 = 1.2 GHz on the little cluster, big
 *                  untouched) is deliberately not a max-clock "gaming" boost.
 *  screen-off cap  while the panel backlight reads 0, the clusters are capped
 *                  (little 1.2 GHz, big 1.0 GHz) for background work in
 *                  standby. Any key or touch lifts the cap at once, with a 1 s
 *                  grace before the next check, so waking up never runs capped.
 *                  The check is a deferrable 2 s poll: it never wakes an idle
 *                  CPU on its own.
 *
 * Idea credit: SuiKernel (LoggingNewMemory) -- "Sandevistan Boot",
 * "Tenebrion Battery" and "Yamada Gaming Boost", reimplemented and toned down.
 *
 * Tunables: /sys/module/rs4_balance/parameters/
 *
 * KMI: a new self-contained built-in driver; no struct or existing-symbol
 * change. It reads the LED core's exported leds_list (drivers/leds/leds.h).
 */

#define pr_fmt(fmt) "rs4_balance: " fmt

#include <linux/cpufreq.h>
#include <linux/cpufreq_limit.h>
#include <linux/init.h>
#include <linux/input.h>
#include <linux/jiffies.h>
#include <linux/leds.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/mutex.h>
#include <linux/pm_qos.h>
#include <linux/slab.h>
#include <linux/timekeeping.h>
#include <linux/workqueue.h>

#include "../leds/leds.h"

enum { CL_LTL = 0, CL_BIG, NR_CL };
static const unsigned int cl_cpu[NR_CL] = { 0, 6 };

/* ---- tunables ---------------------------------------------------------- */

static unsigned int boot_boost_ms = 60000;
module_param(boot_boost_ms, uint, 0444);
MODULE_PARM_DESC(boot_boost_ms, "full clock until this much uptime (0 = off)");

static bool touch_boost = true;
module_param(touch_boost, bool, 0644);

static unsigned int touch_boost_freq = 300000;
module_param(touch_boost_freq, uint, 0644);
MODULE_PARM_DESC(touch_boost_freq, "unified cpufreq_limit value (300000 = little 1.2 GHz)");

static unsigned int touch_boost_ms = 120;
module_param(touch_boost_ms, uint, 0644);

static bool screen_off_cap = true;
module_param(screen_off_cap, bool, 0644);

static unsigned int screen_off_ltl_max = 1200000;
module_param(screen_off_ltl_max, uint, 0644);

static unsigned int screen_off_big_max = 1000000;
module_param(screen_off_big_max, uint, 0644);

static unsigned int screen_poll_ms = 2000;
module_param(screen_poll_ms, uint, 0644);

/* ---- read-only state ---------------------------------------------------- */

static bool boot_boosting = true;
module_param_named(boot_boost_active, boot_boosting, bool, 0444);

static bool screen_off;
module_param_named(screen_is_off, screen_off, bool, 0444);

static bool capped;
module_param_named(screen_cap_active, capped, bool, 0444);

/* ---- freq_qos requests, one set per cluster ----------------------------- */

static DEFINE_MUTEX(rs4_lock);
static struct cpufreq_policy *cl_policy[NR_CL];
static struct freq_qos_request boot_min_req[NR_CL];
static struct freq_qos_request off_max_req[NR_CL];

static int cluster_of(struct cpufreq_policy *policy)
{
	int cl;

	for (cl = 0; cl < NR_CL; cl++)
		if (cpumask_test_cpu(cl_cpu[cl], policy->related_cpus))
			return cl;
	return -1;
}

static s32 off_cap_for(int cl)
{
	if (!capped)
		return FREQ_QOS_MAX_DEFAULT_VALUE;
	return cl == CL_LTL ? screen_off_ltl_max : screen_off_big_max;
}

/* Caller holds rs4_lock. */
static void apply_requests(void)
{
	int cl;

	for (cl = 0; cl < NR_CL; cl++) {
		if (!cl_policy[cl])
			continue;
		freq_qos_update_request(&boot_min_req[cl], boot_boosting ?
			cl_policy[cl]->cpuinfo.max_freq : FREQ_QOS_MIN_DEFAULT_VALUE);
		freq_qos_update_request(&off_max_req[cl], off_cap_for(cl));
	}
}

static int rs4_policy_notifier(struct notifier_block *nb,
			       unsigned long event, void *data)
{
	struct cpufreq_policy *policy = data;
	int cl = cluster_of(policy);

	if (cl < 0)
		return NOTIFY_DONE;

	mutex_lock(&rs4_lock);
	if (event == CPUFREQ_CREATE_POLICY && !cl_policy[cl]) {
		if (freq_qos_add_request(&policy->constraints, &boot_min_req[cl],
					 FREQ_QOS_MIN, FREQ_QOS_MIN_DEFAULT_VALUE) < 0)
			goto out;
		if (freq_qos_add_request(&policy->constraints, &off_max_req[cl],
					 FREQ_QOS_MAX, FREQ_QOS_MAX_DEFAULT_VALUE) < 0) {
			freq_qos_remove_request(&boot_min_req[cl]);
			goto out;
		}
		cl_policy[cl] = policy;
		apply_requests();
	} else if (event == CPUFREQ_REMOVE_POLICY && cl_policy[cl] == policy) {
		freq_qos_remove_request(&boot_min_req[cl]);
		freq_qos_remove_request(&off_max_req[cl]);
		cl_policy[cl] = NULL;
	}
out:
	mutex_unlock(&rs4_lock);
	return NOTIFY_OK;
}

static struct notifier_block rs4_policy_nb = {
	.notifier_call = rs4_policy_notifier,
};

/* ---- screen state: the panel backlight --------------------------------- */

static unsigned long wake_grace_until;
static void screen_poll_fn(struct work_struct *work);
static DECLARE_DEFERRABLE_WORK(screen_poll_work, screen_poll_fn);

/* -1: no backlight LED (e.g. recovery), else its brightness. */
static int backlight_brightness(void)
{
	struct led_classdev *led;
	int bri = -1;

	down_read(&leds_list_lock);
	list_for_each_entry(led, &leds_list, node) {
		if (led->name && !strcmp(led->name, "lcd-backlight")) {
			led_update_brightness(led);
			bri = led->brightness;
			break;
		}
	}
	up_read(&leds_list_lock);
	return bri;
}

static void screen_poll_fn(struct work_struct *work)
{
	bool off = backlight_brightness() == 0 &&
		   time_after_eq(jiffies, wake_grace_until);

	mutex_lock(&rs4_lock);
	if (off != screen_off || capped != (off && screen_off_cap)) {
		screen_off = off;
		capped = off && screen_off_cap;
		apply_requests();
	}
	mutex_unlock(&rs4_lock);

	queue_delayed_work(system_power_efficient_wq, &screen_poll_work,
			   msecs_to_jiffies(max(screen_poll_ms, 250U)));
}

/* A key or touch while dark: lift the cap now, look again after the grace. */
static void screen_wake_fn(struct work_struct *work)
{
	mutex_lock(&rs4_lock);
	wake_grace_until = jiffies + HZ;
	screen_off = false;
	capped = false;
	apply_requests();
	mutex_unlock(&rs4_lock);
	mod_delayed_work(system_power_efficient_wq, &screen_poll_work, HZ);
}
static DECLARE_WORK(screen_wake_work, screen_wake_fn);

/* ---- boot boost ----------------------------------------------------------- */

static void boot_end_fn(struct work_struct *work)
{
	mutex_lock(&rs4_lock);
	boot_boosting = false;
	apply_requests();
	mutex_unlock(&rs4_lock);
	pr_info("boot boost released\n");

	/* The screen-off cap starts only now, so it never fights the boost. */
	queue_delayed_work(system_power_efficient_wq, &screen_poll_work, 0);
}
static DECLARE_DELAYED_WORK(boot_end_work, boot_end_fn);

/* ---- touch boost ---------------------------------------------------------- */

static atomic_t touch_want = ATOMIC_INIT(0);

static void touch_apply_fn(struct work_struct *work)
{
	if (atomic_read(&touch_want))
		set_freq_limit(DVFS_TOUCH_ID, touch_boost_freq);
	else
		set_freq_limit(DVFS_TOUCH_ID, (unsigned int)-1);
}
static DECLARE_WORK(touch_apply_work, touch_apply_fn);

static void touch_end_fn(struct work_struct *work)
{
	atomic_set(&touch_want, 0);
	queue_work(system_highpri_wq, &touch_apply_work);
}
static DECLARE_DELAYED_WORK(touch_end_work, touch_end_fn);

#define RS4_HANDLE_TOUCH	1UL

static void rs4_input_event(struct input_handle *handle, unsigned int type,
			    unsigned int code, int value)
{
	bool is_touch = (unsigned long)handle->private == RS4_HANDLE_TOUCH;

	if (type != EV_ABS && type != EV_KEY)
		return;

	if (READ_ONCE(screen_off)) {
		queue_work(system_highpri_wq, &screen_wake_work);
		return;
	}

	if (!is_touch || !READ_ONCE(touch_boost))
		return;

	if (atomic_xchg(&touch_want, 1) == 0)
		queue_work(system_highpri_wq, &touch_apply_work);
	mod_delayed_work(system_wq, &touch_end_work,
			 msecs_to_jiffies(READ_ONCE(touch_boost_ms)));
}

static int rs4_input_connect(struct input_handler *handler,
			     struct input_dev *dev,
			     const struct input_device_id *id)
{
	struct input_handle *handle;
	bool touch = test_bit(INPUT_PROP_DIRECT, dev->propbit) &&
		     test_bit(EV_ABS, dev->evbit);
	bool power = test_bit(EV_KEY, dev->evbit) &&
		     test_bit(KEY_POWER, dev->keybit);
	int ret;

	if (!touch && !power)
		return -ENODEV;

	handle = kzalloc(sizeof(*handle), GFP_KERNEL);
	if (!handle)
		return -ENOMEM;

	handle->dev = dev;
	handle->handler = handler;
	handle->name = "rs4_balance";
	handle->private = (void *)(touch ? RS4_HANDLE_TOUCH : 0UL);

	ret = input_register_handle(handle);
	if (ret)
		goto err_free;
	ret = input_open_device(handle);
	if (ret)
		goto err_unregister;
	return 0;

err_unregister:
	input_unregister_handle(handle);
err_free:
	kfree(handle);
	return ret;
}

static void rs4_input_disconnect(struct input_handle *handle)
{
	input_close_device(handle);
	input_unregister_handle(handle);
	kfree(handle);
}

static const struct input_device_id rs4_input_ids[] = {
	{	/* touchscreens (filtered to INPUT_PROP_DIRECT in connect) */
		.flags = INPUT_DEVICE_ID_MATCH_EVBIT | INPUT_DEVICE_ID_MATCH_ABSBIT,
		.evbit = { BIT_MASK(EV_ABS) },
		.absbit = { [BIT_WORD(ABS_MT_POSITION_X)] = BIT_MASK(ABS_MT_POSITION_X) },
	},
	{	/* power key: wakes the device, lifts the screen-off cap */
		.flags = INPUT_DEVICE_ID_MATCH_EVBIT | INPUT_DEVICE_ID_MATCH_KEYBIT,
		.evbit = { BIT_MASK(EV_KEY) },
		.keybit = { [BIT_WORD(KEY_POWER)] = BIT_MASK(KEY_POWER) },
	},
	{ },
};

static struct input_handler rs4_input_handler = {
	.event		= rs4_input_event,
	.connect	= rs4_input_connect,
	.disconnect	= rs4_input_disconnect,
	.name		= "rs4_balance",
	.id_table	= rs4_input_ids,
};

/* ---- init ----------------------------------------------------------------- */

static int __init rs4_balance_init(void)
{
	u64 up_ms = ktime_to_ms(ktime_get_boottime());
	int ret;

	boot_boosting = boot_boost_ms && up_ms < boot_boost_ms;

	ret = cpufreq_register_notifier(&rs4_policy_nb, CPUFREQ_POLICY_NOTIFIER);
	if (ret) {
		pr_err("policy notifier registration failed %d\n", ret);
		return ret;
	}

	ret = input_register_handler(&rs4_input_handler);
	if (ret)
		pr_err("input handler registration failed %d\n", ret);

	queue_delayed_work(system_power_efficient_wq, &boot_end_work,
			   boot_boosting ? msecs_to_jiffies(boot_boost_ms - up_ms) : 0);

	pr_info("boot boost %s, touch boost %u for %u ms, screen-off cap %u/%u kHz\n",
		boot_boosting ? "on" : "off", touch_boost_freq, touch_boost_ms,
		screen_off_ltl_max, screen_off_big_max);
	return 0;
}
late_initcall(rs4_balance_init);
