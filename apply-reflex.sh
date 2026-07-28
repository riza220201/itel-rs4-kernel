#!/usr/bin/env bash
# Apply the Reflex CPUFreq governor to $KERNEL_SRC (called by build.sh for ALL
# variants, on a pristine git tree that is git-reverted afterwards).
#
# Reflex = firelzrd/reflex v0.3.1 ("interactive + schedutil hybrid" governor):
# an idle-time (kcpustat) based hispeed floor blended into schedutil PELT
# scaling with a PELT-complementary 32 ms exponential decay. Selected via
# scaling_governor "reflex" — the itel S666LN device tree writes it to policy0
# (little) and policy6 (big). The clean-GKI Riza kernel lacks it (stock has it);
# this backports the upstream (6.x) governor to android12-5.10.
#
# WHY it is KMI-safe: every change is a PURE ADDITION —
#   * a new self-contained driver drivers/cpufreq/cpufreq_reflex.c,
#   * five new EXPORT_SYMBOL_GPL helper wrappers appended to schedutil.c (they
#     reach kernel/sched-private util primitives for the driver-side governor),
#   * their declarations in include/linux/sched/cpufreq.h,
#   * a Kconfig entry + a Makefile line.
# No struct changes, no existing-symbol signature changes -> genksyms computes
# byte-identical module_layout and vendor CRCs. The build's KMI gate re-verifies
# 198/198 every build. (The three EXPORT_SYMBOLs firelzrd's upstream adds to
# kthread.c / tick-sched.c / sched/cpufreq.c are ALREADY present on 5.10, and the
# x86 aperfmperf hunk is irrelevant on arm64 — both dropped.)
#
# 5.10 backport deltas vs the 6.x upstream helpers (all inside schedutil.c):
#   * effective util comes from 5.10's exported schedutil_cpu_util() (identical
#     to what sugov_get_util() feeds the frequency map) — reflex's PELT path is
#     therefore byte-identical to schedutil on this tree;
#   * sched_ext (scx_*) does not exist on 5.10 -> cpufreq_scx_switched_all()==false;
#   * uclamp_rq_is_capped() does not exist on 5.10 -> cpufreq_cpu_uclamp_capped()
#     ==false (an update-skip optimization only; correctness unaffected);
#   * reference frequency mirrors get_next_freq()'s choice.
set -euo pipefail
KERNEL_SRC="${KERNEL_SRC:?}"; PROJ="${PROJ:?}"
GOV="${REFLEX_GOV:-$PROJ/patches/cpufreq_reflex.c}"
say(){ echo "  [reflex] $*"; }
die(){ echo "✗ [reflex] $*" >&2; exit 1; }

[[ -f "$GOV" ]] || die "governor source missing: $GOV"

# Sanity: the anchors the integration relies on must exist unmodified (guards
# against a kernel-source bump silently shifting them).
grep -q 'EXPORT_SYMBOL_GPL(schedutil_cpu_util);' "$KERNEL_SRC/kernel/sched/cpufreq_schedutil.c" \
  || die "schedutil_cpu_util export anchor not found — kernel changed, re-port reflex"
grep -q '^comment "CPU frequency scaling drivers"' "$KERNEL_SRC/drivers/cpufreq/Kconfig" \
  || die "Kconfig anchor 'comment CPU frequency scaling drivers' not found — re-port reflex"
grep -q '#endif /\* _LINUX_SCHED_CPUFREQ_H \*/' "$KERNEL_SRC/include/linux/sched/cpufreq.h" \
  || die "cpufreq.h endif anchor not found — re-port reflex"

# ── 1. governor source ──────────────────────────────────────────────────────
cp "$GOV" "$KERNEL_SRC/drivers/cpufreq/cpufreq_reflex.c"
say "staged drivers/cpufreq/cpufreq_reflex.c"

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
	  Reflex is an interactive + schedutil hybrid governor.  On an
	  idle-to-busy transition it sets an instant "hispeed" frequency
	  floor from real CPU busy% (kcpustat idle-time counters), then
	  blends it into schedutil's PELT-proportional scaling with a
	  PELT-complementary 32 ms exponential decay.  After ~320 ms the
	  hispeed floor is negligible and PELT takes full control.

	  Tunables live under /sys/devices/system/cpu/cpufreq/reflex/.

	  If in doubt, say M.

EOKC
  awk 'FNR==NR{b=b $0 ORS; next} /^comment "CPU frequency scaling drivers"/ && !d {printf "%s", b; d=1} {print}' /tmp/reflex_kconfig.$$ "$KC" > "$KC.new" && mv "$KC.new" "$KC"
  rm -f /tmp/reflex_kconfig.$$
  grep -q 'CPU_FREQ_GOV_REFLEX' "$KC" || die "Kconfig insert failed"
fi
say "Kconfig += CPU_FREQ_GOV_REFLEX"

# ── 4. schedutil.c: append the 5 exported helper wrappers (5.10-adapted) ─────
SU="$KERNEL_SRC/kernel/sched/cpufreq_schedutil.c"
if ! grep -q 'cpufreq_get_effective_util' "$SU"; then
  cat >> "$SU" <<'EOSU'

/*********** Exported helpers for the reflex cpufreq governor (5.10) ***********/
/*
 * Backport of firelzrd/reflex v0.3.1's schedutil helpers. They live here so
 * the driver-side reflex governor can reach kernel/sched-private util
 * primitives (cpu_util_cfs, cpu_bw_dl, FREQUENCY_UTIL) via the already-exported
 * schedutil_cpu_util(). All pure additions -> KMI-inert.
 */
unsigned long cpufreq_get_capacity_ref_freq(struct cpufreq_policy *policy)
{
	/* Mirror get_next_freq()'s reference-frequency choice. */
	if (arch_scale_freq_invariant())
		return policy->cpuinfo.max_freq;
	return policy->cur;
}
EXPORT_SYMBOL_GPL(cpufreq_get_capacity_ref_freq);

void cpufreq_get_effective_util(int cpu, unsigned long boost,
				unsigned long *out_util,
				unsigned long *out_bw_min)
{
	struct rq *rq = cpu_rq(cpu);
	unsigned long max = arch_scale_cpu_capacity(cpu);
	unsigned long util = cpu_util_cfs(rq);

	/* Identical to 5.10 sugov_get_util(): reflex PELT path == schedutil. */
	util = schedutil_cpu_util(cpu, util, max, FREQUENCY_UTIL, NULL);
	if (boost > util)
		util = boost;

	*out_util = util;
	*out_bw_min = cpu_bw_dl(rq);
}
EXPORT_SYMBOL_GPL(cpufreq_get_effective_util);

bool cpufreq_cpu_dl_bw_exceeded(int cpu, unsigned long bw_min)
{
	return cpu_bw_dl(cpu_rq(cpu)) > bw_min;
}
EXPORT_SYMBOL_GPL(cpufreq_cpu_dl_bw_exceeded);

bool cpufreq_cpu_uclamp_capped(int cpu)
{
	/* 5.10 has no uclamp_rq_is_capped(); an update-skip hint only. */
	return false;
}
EXPORT_SYMBOL_GPL(cpufreq_cpu_uclamp_capped);

bool cpufreq_scx_switched_all(void)
{
	return false;	/* sched_ext does not exist on 5.10 */
}
EXPORT_SYMBOL_GPL(cpufreq_scx_switched_all);
EOSU
  grep -q 'cpufreq_get_effective_util' "$SU" || die "schedutil.c append failed"
fi
say "schedutil.c += reflex helpers"

# ── 5. cpufreq.h: declare the helpers (before the trailing #endif) ───────────
HDR="$KERNEL_SRC/include/linux/sched/cpufreq.h"
if ! grep -q 'cpufreq_get_effective_util' "$HDR"; then
  cat > /tmp/reflex_hdr.$$ <<'EOHDR'
/* Exported helpers for the reflex cpufreq governor (backport). */
unsigned long cpufreq_get_capacity_ref_freq(struct cpufreq_policy *policy);
void cpufreq_get_effective_util(int cpu, unsigned long boost,
				unsigned long *out_util,
				unsigned long *out_bw_min);
bool cpufreq_cpu_dl_bw_exceeded(int cpu, unsigned long bw_min);
bool cpufreq_cpu_uclamp_capped(int cpu);
bool cpufreq_scx_switched_all(void);
EOHDR
  awk 'FNR==NR{b=b $0 ORS; next} /^#endif \/\* _LINUX_SCHED_CPUFREQ_H \*\// && !d {printf "%s", b; d=1} {print}' /tmp/reflex_hdr.$$ "$HDR" > "$HDR.new" && mv "$HDR.new" "$HDR"
  rm -f /tmp/reflex_hdr.$$
  grep -q 'cpufreq_get_effective_util' "$HDR" || die "cpufreq.h insert failed"
fi
say "cpufreq.h += reflex helper decls"

say "Reflex governor applied (KMI-safe; select via scaling_governor \"reflex\")"
