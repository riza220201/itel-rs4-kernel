#!/usr/bin/env bash
# Apply the Reflex CPUFreq governor to $KERNEL_SRC (called by build.sh for ALL
# variants, on a pristine git tree that is git-reverted afterwards).
#
# Reflex = firelzrd/reflex v0.4.0: schedutil plus a measured fast path for rising
# load. Each CPU measures, from its idle time and frequency scale, the demand it
# actually ran (H, a PELT-paced envelope) and how much it ran lately (N); work on
# a CPU that is behind runs at s*(p * lambda), the speed that best trades latency
# against energy, tabulated from the Energy Model (or a cube law). The
# latency_weight tunable sets lambda. (v0.3.1, shipped through v8, was a
# kcpustat busy% "hispeed" floor with a 32 ms decay -- a different algorithm.)
# Selected via scaling_governor "reflex" -- the itel S666LN device tree writes it
# to policy0 (little) and policy6 (big). This backports the upstream 6.12 patch
# to android12-5.10.
#
# WHY it is KMI-safe: every change is a PURE ADDITION —
#   * a new self-contained driver drivers/cpufreq/cpufreq_reflex.c + its
#     cpufreq_reflex_compat.h,
#   * four new helpers appended to schedutil.c / pelt.c (they reach
#     kernel/sched-private primitives for the driver-side governor),
#   * their declarations in include/linux/sched/cpufreq.h,
#   * a Kconfig entry + a Makefile line.
# No struct changes, no existing-symbol signature changes -> genksyms computes
# byte-identical module_layout and vendor CRCs. The build's KMI gate re-verifies
# 198/198 every build. (Upstream's EXPORT_SYMBOLs of idle_cpu, kthread_bind_mask,
# topology_scale_freq_invariant, cpufreq_this_cpu_can_update and the
# cpufreq_driver_* calls are only needed for a MODULE; the governor is built in
# (config/reflex.fragment), and the x86 aperfmperf hunk is irrelevant on arm64 --
# all dropped.)
#
# 5.10 backport deltas (the governor itself differs from upstream only where
# marked "5.10 backport"; kernel-version shims live in cpufreq_reflex_compat.h):
#   * 6.12 utilization semantics: cpufreq_get_effective_util() returns the util
#     WITH the DVFS headroom, capped at the rq's uclamp max and floored at the DL
#     bandwidth (6.12 effective_cpu_util() + sugov_effective_cpu_perf()), built on
#     5.10's exported schedutil_cpu_util(); the reference frequency is 6.12's
#     get_capacity_ref_freq() (max_freq when frequency-invariant, else cur * 1.25);
#     and the compat header gives map_util_freq() 6.12's no-headroom meaning.
#   * cpufreq_pelt_decay() wraps 5.10 pelt.c's static decay_load() (unchanged since).
#   * Energy Model: 5.10's fixed pd->table instead of 6.9's RCU em_perf_table.
#   * adjust_perf path compiled out (no cpufreq_driver_adjust_perf() on 5.10, and
#     the MTK cpufreq driver has no adjust_perf callback).
set -euo pipefail
KERNEL_SRC="${KERNEL_SRC:?}"; PROJ="${PROJ:?}"
GOV="${REFLEX_GOV:-$PROJ/patches/cpufreq_reflex.c}"
COMPAT="${REFLEX_COMPAT:-$PROJ/patches/cpufreq_reflex_compat.h}"
say(){ echo "  [reflex] $*"; }
die(){ echo "✗ [reflex] $*" >&2; exit 1; }

[[ -f "$GOV" ]] || die "governor source missing: $GOV"
[[ -f "$COMPAT" ]] || die "compat header missing: $COMPAT"

# Sanity: the anchors the integration relies on must exist unmodified (guards
# against a kernel-source bump silently shifting them).
grep -q 'EXPORT_SYMBOL_GPL(schedutil_cpu_util);' "$KERNEL_SRC/kernel/sched/cpufreq_schedutil.c" \
  || die "schedutil_cpu_util export anchor not found — kernel changed, re-port reflex"
grep -q '^comment "CPU frequency scaling drivers"' "$KERNEL_SRC/drivers/cpufreq/Kconfig" \
  || die "Kconfig anchor 'comment CPU frequency scaling drivers' not found — re-port reflex"
grep -q '#endif /\* _LINUX_SCHED_CPUFREQ_H \*/' "$KERNEL_SRC/include/linux/sched/cpufreq.h" \
  || die "cpufreq.h endif anchor not found — re-port reflex"
grep -q '^static u64 decay_load(u64 val, u64 n)$' "$KERNEL_SRC/kernel/sched/pelt.c" \
  || die "pelt.c decay_load() anchor not found — re-port reflex"
grep -q '^static u32 __accumulate_pelt_segments(' "$KERNEL_SRC/kernel/sched/pelt.c" \
  || die "pelt.c __accumulate_pelt_segments() anchor not found — re-port reflex"

# ── 1. governor source + compat header ──────────────────────────────────────
cp "$GOV" "$KERNEL_SRC/drivers/cpufreq/cpufreq_reflex.c"
cp "$COMPAT" "$KERNEL_SRC/drivers/cpufreq/cpufreq_reflex_compat.h"
say "staged drivers/cpufreq/cpufreq_reflex.c + cpufreq_reflex_compat.h"

# ── 2. Makefile ─────────────────────────────────────────────────────────────
MK="$KERNEL_SRC/drivers/cpufreq/Makefile"
if ! grep -q 'cpufreq_reflex.o' "$MK"; then
  # anchor on the attr_set line (present on 5.10) to keep it with the governors
  awk '{print} /CONFIG_CPU_FREQ_GOV_ATTR_SET.*cpufreq_governor_attr_set\.o/ && !d {print "obj-$(CONFIG_CPU_FREQ_GOV_REFLEX)\t+= cpufreq_reflex.o"; d=1}' "$MK" > "$MK.new" && mv "$MK.new" "$MK"
  grep -q 'cpufreq_reflex.o' "$MK" || die "Makefile insert failed"
fi
say "Makefile += cpufreq_reflex.o"

# ── 3. Kconfig (insert the governor option before the drivers comment) ───────
KC="$KERNEL_SRC/drivers/cpufreq/Kconfig"
if ! grep -q 'CPU_FREQ_GOV_REFLEX' "$KC"; then
  cat > /tmp/reflex_kconfig.$$ <<'EOKC'
config CPU_FREQ_GOV_REFLEX
	tristate "'reflex' cpufreq policy governor"
	default m
	depends on CPU_FREQ && SMP && CPU_FREQ_GOV_SCHEDUTIL
	select CPU_FREQ_GOV_ATTR_SET
	select IRQ_WORK
	help
	  This governor is schedutil plus a measured fast path for rising
	  load.  Each CPU measures, from its idle time and frequency scale,
	  the demand it actually ran; an interval without any idle means the
	  CPU is falling behind, and the governor then runs it at the speed
	  that best trades latency against energy instead of waiting for
	  PELT to ramp up.  Otherwise it keeps up with demand like schedutil,
	  never below the most efficient speed when that is known.  Work on
	  a CPU that has not been seen running lately is presumed behind, the
	  more so the less it has run.

	  The speeds come from the Energy Model when one is registered,
	  else from ACPI CPPC and a cube-law power model.  The latency_weight
	  tunable sets the trade-off; 1000 runs work that is behind at the
	  maximum frequency (upstream's default); this kernel defaults to 300.

	  To compile this driver as a module, choose M here: the
	  module will be called cpufreq_reflex.

	  If in doubt, say M.

EOKC
  awk 'FNR==NR{b=b $0 ORS; next} /^comment "CPU frequency scaling drivers"/ && !d {printf "%s", b; d=1} {print}' /tmp/reflex_kconfig.$$ "$KC" > "$KC.new" && mv "$KC.new" "$KC"
  rm -f /tmp/reflex_kconfig.$$
  grep -q 'CPU_FREQ_GOV_REFLEX' "$KC" || die "Kconfig insert failed"
fi
say "Kconfig += CPU_FREQ_GOV_REFLEX"

# ── 4. schedutil.c: append the 3 helpers (5.10-adapted, 6.12 semantics) ──────
SU="$KERNEL_SRC/kernel/sched/cpufreq_schedutil.c"
if ! grep -q 'cpufreq_get_effective_util' "$SU"; then
  cat >> "$SU" <<'EOSU'

/*********** Exported helpers for the reflex cpufreq governor (5.10) ***********/
/*
 * Backport of firelzrd/reflex v0.4.0's schedutil helpers, with 6.12 semantics
 * (the DVFS headroom lives in the util and in the non-invariant reference
 * frequency, not in map_util_freq()). They live here so the driver-side
 * governor can reach kernel/sched-private primitives (cpu_util_cfs, cpu_bw_dl,
 * uclamp_rq_util_with, FREQUENCY_UTIL) via the already-exported
 * schedutil_cpu_util(). All pure additions -> KMI-inert.
 */
unsigned long cpufreq_get_capacity_ref_freq(struct cpufreq_policy *policy)
{
	/* 6.12 get_capacity_ref_freq() (no arch_scale_freq_ref() on 5.10). */
	if (arch_scale_freq_invariant())
		return policy->cpuinfo.max_freq;
	return policy->cur + (policy->cur >> 2);
}
EXPORT_SYMBOL_GPL(cpufreq_get_capacity_ref_freq);

void cpufreq_get_effective_util(int cpu, unsigned long boost,
				unsigned long *out_util,
				unsigned long *out_bw_min,
				unsigned long *out_bw_max)
{
	struct rq *rq = cpu_rq(cpu);
	unsigned long scale = arch_scale_cpu_capacity(cpu);
	unsigned long util, min, max;

	/* 6.12 effective_cpu_util(), from 5.10's own FREQUENCY_UTIL estimate. */
	util = schedutil_cpu_util(cpu, cpu_util_cfs(rq), scale, FREQUENCY_UTIL, NULL);
	util = max(util, boost);
	min = cpu_bw_dl(rq);
	max = uclamp_rq_util_with(rq, scale, NULL);	/* scale, capped by uclamp max */

	/* 6.12 sugov_effective_cpu_perf(): headroom, capped at max, floored at min. */
	util = util + (util >> 2);
	if (util > max)
		util = max;
	*out_util = max(min, util);
	*out_bw_min = min;
	*out_bw_max = max;
}
EXPORT_SYMBOL_GPL(cpufreq_get_effective_util);

bool cpufreq_cpu_dl_bw_exceeded(int cpu, unsigned long bw_min)
{
	return cpu_bw_dl(cpu_rq(cpu)) > bw_min;
}
EXPORT_SYMBOL_GPL(cpufreq_cpu_dl_bw_exceeded);
EOSU
  grep -q 'cpufreq_get_effective_util' "$SU" || die "schedutil.c append failed"
fi
say "schedutil.c += reflex helpers"

# ── 5. pelt.c: cpufreq_pelt_decay() next to the static decay_load() ──────────
PELT="$KERNEL_SRC/kernel/sched/pelt.c"
if ! grep -q 'cpufreq_pelt_decay' "$PELT"; then
  cat > /tmp/reflex_pelt.$$ <<'EOPELT'
#ifdef CONFIG_CPU_FREQ
/**
 * cpufreq_pelt_decay - Decay a value over a span exactly as PELT does.
 * @val: the value to decay.
 * @delta_ns: the span, in ns; counted in whole PELT periods (1024 * 1024 ns).
 *
 * For cpufreq governors that keep their own PELT-paced signal.
 */
u64 cpufreq_pelt_decay(u64 val, u64 delta_ns)
{
	return decay_load(val, delta_ns >> 20);
}
EXPORT_SYMBOL_GPL(cpufreq_pelt_decay);
#endif

EOPELT
  awk 'FNR==NR{b=b $0 ORS; next} /^static u32 __accumulate_pelt_segments\(/ && !d {printf "%s", b; d=1} {print}' /tmp/reflex_pelt.$$ "$PELT" > "$PELT.new" && mv "$PELT.new" "$PELT"
  rm -f /tmp/reflex_pelt.$$
  grep -q 'cpufreq_pelt_decay' "$PELT" || die "pelt.c insert failed"
fi
say "pelt.c += cpufreq_pelt_decay"

# ── 6. cpufreq.h: declare the helpers (before the trailing #endif) ───────────
HDR="$KERNEL_SRC/include/linux/sched/cpufreq.h"
if ! grep -q 'cpufreq_get_effective_util' "$HDR"; then
  cat > /tmp/reflex_hdr.$$ <<'EOHDR'
/* Exported helpers for the reflex cpufreq governor (backport). */
unsigned long cpufreq_get_capacity_ref_freq(struct cpufreq_policy *policy);
void cpufreq_get_effective_util(int cpu, unsigned long boost,
				unsigned long *out_util,
				unsigned long *out_bw_min,
				unsigned long *out_bw_max);
bool cpufreq_cpu_dl_bw_exceeded(int cpu, unsigned long bw_min);
u64 cpufreq_pelt_decay(u64 val, u64 delta_ns);
EOHDR
  awk 'FNR==NR{b=b $0 ORS; next} /^#endif \/\* _LINUX_SCHED_CPUFREQ_H \*\// && !d {printf "%s", b; d=1} {print}' /tmp/reflex_hdr.$$ "$HDR" > "$HDR.new" && mv "$HDR.new" "$HDR"
  rm -f /tmp/reflex_hdr.$$
  grep -q 'cpufreq_get_effective_util' "$HDR" || die "cpufreq.h insert failed"
fi
say "cpufreq.h += reflex helper decls"

say "Reflex $(sed -n 's/^#define CPUFREQ_REFLEX_VERSION *"\(.*\)"/\1/p' "$GOV") governor applied (KMI-safe; select via scaling_governor \"reflex\")"
