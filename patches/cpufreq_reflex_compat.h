/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Reflex CPUFreq governor: the only kernel-version differences.
 * cpufreq_reflex.c is byte-identical across versions; this file is not.
 *
 * Linux 5.10 (android12-5.10 GKI backport of reflex v0.4.0, written for the
 * 6.12 file of the same name):
 *
 * - Utilization semantics follow 6.12, where the DVFS headroom moved out of
 *   map_util_freq() into map_util_perf() and the effective-util helper.
 *   5.10's own map_util_freq() still adds 1.25x, so it is overridden here with
 *   6.12's plain freq * util / cap; otherwise every request would carry the
 *   headroom twice (cpufreq_get_effective_util() already returns it, and the
 *   measured envelope H gets it from map_util_perf()).
 * - The Energy Model table is a plain array fixed at registration
 *   (pd->table); 6.9+ made it an RCU-managed struct em_perf_table that can be
 *   replaced at runtime. Mapped onto the 5.10 fields, the "table changed"
 *   check always reads unchanged, which is true here. Its power is in mW, not
 *   uW: read through rfx_em_power().
 * - cpufreq_driver_adjust_perf() does not exist (~5.12) and the MTK cpufreq
 *   driver has no adjust_perf callback: the adjust_perf update path is compiled
 *   out in cpufreq_reflex.c, so no rfx_adjust_perf() is needed.
 * - CPPC is ACPI-only (CONFIG_ACPI_CPPC_LIB is off on arm64 Android): the
 *   cube-law floor gets no CPPC lower bound, as on any non-CPPC system.
 */
#ifndef _CPUFREQ_REFLEX_COMPAT_H
#define _CPUFREQ_REFLEX_COMPAT_H

static inline unsigned long map_util_perf(unsigned long util)
{
	return util + (util >> 2);
}

static inline unsigned long rfx_map_util_freq(unsigned long util,
					      unsigned long freq,
					      unsigned long cap)
{
	return freq * util / cap;
}
#define map_util_freq(util, freq, cap)	rfx_map_util_freq(util, freq, cap)

#ifdef CONFIG_ENERGY_MODEL
#define em_perf_table	em_perf_state
#define em_table	table

static inline struct em_perf_state *
em_perf_state_from_pd(struct em_perf_domain *pd)
{
	return pd->table;
}

/*
 * EM power is in milliwatts on 5.10; 5.19 (ae6ccaa65038, "PM: EM: convert power
 * field to micro-Watts precision") made it microwatts, which the floor scores
 * assume. Read in mW, power * 1000 * (RFX_FLOOR_N - 1) / freq_khz collapses to
 * a few integers across a whole table and every tie goes to the faster state:
 * on the MT6789 little cluster (24 states) 2 distinct scores and s*(0) =
 * 1.8 GHz -- the phone idled at 1818 MHz with latency_weight=0 -- where uW
 * gives 23 distinct scores and s*(0) = 650 MHz (big: 1.1 GHz vs 725 MHz).
 */
static inline u64 rfx_em_power(const struct em_perf_state *ps)
{
	return (u64)ps->power * 1000;
}
#endif /* CONFIG_ENERGY_MODEL */

#endif /* _CPUFREQ_REFLEX_COMPAT_H */
