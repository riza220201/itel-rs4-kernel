#!/usr/bin/env bash
# Apply the "rs4" set to $KERNEL_SRC (called by build.sh for ALL variants, on a
# pristine git tree that is git-reverted afterwards).
#
# Two halves, both pure additions (plus one guarded default in block/elevator.c):
#
#   SAMSUNG COMPAT -- for the One UI 8 port (itel-rs4-devicetree, PORTROM):
#     drivers/cpufreq/cpufreq_limit.c    Samsung's unified CPU limit
#       (/sys/devices/system/cpu/cpufreq_limit/). GOS/IPM needs it or Game
#       Booster's performance monitor reads 0. Samsung MTK driver (A15/A16 4G,
#       5.10) with the A17 4G (SM-A175F, the port's donor) DT values.
#     drivers/power/supply/rs4_pass_through.c   Samsung's battery pass_through
#       node, mapped onto itel's tran_aichg_disable_charger bypass, so Game
#       Booster's "Pause USB PD charging when gaming" works without patching
#       services.jar.
#
#   BALANCED BEHAVIOUR -- ideas from SuiKernel, toned down:
#     drivers/cpufreq/rs4_balance.c   boot boost (60 s), modest touch boost
#       (little 1.2 GHz floor for 120 ms, via cpufreq_limit's touch slot),
#       screen-off cap (little 1.2 / big 1.0 GHz while the backlight is off).
#     block/elevator.c   default I/O scheduler "none" instead of mq-deadline
#       for single-queue devices (CONFIG_RS4_IOSCHED_DEFAULT_NONE).
#
# WHY it is KMI-safe: new self-contained built-in drivers + Kconfig/Makefile
# lines + one IS_ENABLED() early return in elevator_get_default(). No struct
# changes, no existing-symbol signature changes. The build's KMI gate
# re-verifies 198/198 every build.
set -euo pipefail
KERNEL_SRC="${KERNEL_SRC:?}"; PROJ="${PROJ:?}"
SRC="$PROJ/patches/rs4"
say(){ echo "  [rs4] $*"; }
die(){ echo "✗ [rs4] $*" >&2; exit 1; }

for f in cpufreq_limit.c cpufreq_limit.h rs4_balance.c rs4_pass_through.c rs4_gpu_ski.c; do
  [[ -f "$SRC/$f" ]] || die "source missing: $SRC/$f"
done

# Anchors the integration relies on (guards against a source bump shifting them).
CFK="$KERNEL_SRC/drivers/cpufreq/Kconfig"
CFM="$KERNEL_SRC/drivers/cpufreq/Makefile"
PSK="$KERNEL_SRC/drivers/power/supply/Kconfig"
PSM="$KERNEL_SRC/drivers/power/supply/Makefile"
IOK="$KERNEL_SRC/block/Kconfig.iosched"
ELV="$KERNEL_SRC/block/elevator.c"
MSK="$KERNEL_SRC/drivers/misc/Kconfig"
MSM="$KERNEL_SRC/drivers/misc/Makefile"
[[ "$(tail -n1 "$MSK")" == "endmenu" ]] || die "drivers/misc/Kconfig no longer ends in endmenu"
[[ -f "$MSM" ]] || die "drivers/misc/Makefile missing"
grep -q '^comment "CPU frequency scaling drivers"' "$CFK" || die "cpufreq Kconfig anchor missing"
grep -q '^obj-\$(CONFIG_CPU_FREQ)[[:space:]]*+= cpufreq.o freq_table.o' "$CFM" || die "cpufreq Makefile anchor missing"
grep -q '^endif # POWER_SUPPLY' "$PSK" || die "power supply Kconfig anchor missing"
grep -q '^obj-\$(CONFIG_POWER_SUPPLY)[[:space:]]*+= power_supply.o' "$PSM" || die "power supply Makefile anchor missing"
grep -q '^menu "IO Schedulers"' "$IOK" || die "iosched Kconfig anchor missing"
grep -q '^static struct elevator_type \*elevator_get_default(struct request_queue \*q)' "$ELV" \
  || die "elevator_get_default anchor missing"
[[ -f "$KERNEL_SRC/drivers/leds/leds.h" ]] || die "drivers/leds/leds.h missing (rs4_balance reads leds_list)"

# ── 1. sources ────────────────────────────────────────────────────────────────
cp "$SRC/cpufreq_limit.h"    "$KERNEL_SRC/include/linux/cpufreq_limit.h"
cp "$SRC/cpufreq_limit.c"    "$KERNEL_SRC/drivers/cpufreq/cpufreq_limit.c"
cp "$SRC/rs4_balance.c"      "$KERNEL_SRC/drivers/cpufreq/rs4_balance.c"
cp "$SRC/rs4_pass_through.c" "$KERNEL_SRC/drivers/power/supply/rs4_pass_through.c"
cp "$SRC/rs4_gpu_ski.c"      "$KERNEL_SRC/drivers/misc/rs4_gpu_ski.c"
say "staged cpufreq_limit.{c,h}, rs4_balance.c, rs4_pass_through.c, rs4_gpu_ski.c"

# ── 2. Makefiles ──────────────────────────────────────────────────────────────
if ! grep -q 'cpufreq_limit.o' "$CFM"; then
  cat >> "$CFM" <<'EOMK'

# rs4: Samsung-compatible unified CPU limit + balanced frequency policy
obj-$(CONFIG_CPU_FREQ_LIMIT)		+= cpufreq_limit.o
obj-$(CONFIG_RS4_BALANCE)		+= rs4_balance.o
EOMK
fi
grep -q 'rs4_balance.o' "$CFM" || die "cpufreq Makefile insert failed"
if ! grep -q 'rs4_pass_through.o' "$PSM"; then
  printf '\n# rs4: Samsung battery pass_through -> itel charger bypass\nobj-$(CONFIG_RS4_PASS_THROUGH)\t+= rs4_pass_through.o\n' >> "$PSM"
fi
grep -q 'rs4_pass_through.o' "$PSM" || die "power supply Makefile insert failed"
if ! grep -q 'rs4_gpu_ski.o' "$MSM"; then
  printf '\n# rs4: Samsung /sys/kernel/gpu (SKI) over the itel GED/gpufreq modules\nobj-$(CONFIG_RS4_GPU_SKI)\t+= rs4_gpu_ski.o\n' >> "$MSM"
fi
grep -q 'rs4_gpu_ski.o' "$MSM" || die "misc Makefile insert failed"
say "Makefiles += cpufreq_limit.o rs4_balance.o rs4_pass_through.o rs4_gpu_ski.o"

# ── 3. Kconfig ────────────────────────────────────────────────────────────────
if ! grep -q 'config CPU_FREQ_LIMIT' "$CFK"; then
  cat > /tmp/rs4_cfk.$$ <<'EOKC'
config CPU_FREQ_LIMIT
	bool "Samsung-compatible unified CPU frequency limit"
	depends on CPU_FREQ && SMP
	help
	  Samsung's /sys/devices/system/cpu/cpufreq_limit interface: one
	  "unified" frequency table across the little and big clusters, with
	  min/max limits backed by freq_qos. One UI's Game Optimizing Service
	  needs it to run its performance engine.

config RS4_BALANCE
	bool "itel RS4 balanced frequency policy (boot/touch boost, screen-off cap)"
	depends on CPU_FREQ_LIMIT && INPUT && LEDS_CLASS
	help
	  Boot boost, a modest touch boost and a screen-off frequency cap,
	  all as freq_qos requests. Tunables under
	  /sys/module/rs4_balance/parameters/.

EOKC
  awk 'FNR==NR{b=b $0 ORS; next} /^comment "CPU frequency scaling drivers"/ && !d {printf "%s", b; d=1} {print}' /tmp/rs4_cfk.$$ "$CFK" > "$CFK.new" && mv "$CFK.new" "$CFK"
  rm -f /tmp/rs4_cfk.$$
fi
grep -q 'config RS4_BALANCE' "$CFK" || die "cpufreq Kconfig insert failed"
if ! grep -q 'config RS4_PASS_THROUGH' "$PSK"; then
  cat > /tmp/rs4_psk.$$ <<'EOKC'
config RS4_PASS_THROUGH
	bool "Samsung battery pass_through mapped to the itel charger bypass"
	depends on POWER_SUPPLY && SYSFS
	help
	  Adds pass_through to the "battery" power supply (as Samsung's
	  sec_battery has) and maps it to itel's tran_aichg_disable_charger,
	  guarded by charger presence and battery level.

EOKC
  awk 'FNR==NR{b=b $0 ORS; next} /^endif # POWER_SUPPLY/ && !d {printf "%s", b; d=1} {print}' /tmp/rs4_psk.$$ "$PSK" > "$PSK.new" && mv "$PSK.new" "$PSK"
  rm -f /tmp/rs4_psk.$$
fi
grep -q 'config RS4_PASS_THROUGH' "$PSK" || die "power supply Kconfig insert failed"
if ! grep -q 'config RS4_IOSCHED_DEFAULT_NONE' "$IOK"; then
  cat > /tmp/rs4_iok.$$ <<'EOKC'
config RS4_IOSCHED_DEFAULT_NONE
	bool "Default to no I/O scheduler (none) on single-queue devices"
	default n
	help
	  Flash storage gains nothing from mq-deadline's reordering; "none"
	  hands requests straight to the device. Schedulers remain selectable
	  at runtime through /sys/block/*/queue/scheduler.

EOKC
  awk 'FNR==NR{b=b $0 ORS; next} {print} /^menu "IO Schedulers"/ && !d {print ""; printf "%s", b; d=1}' /tmp/rs4_iok.$$ "$IOK" > "$IOK.new" && mv "$IOK.new" "$IOK"
  rm -f /tmp/rs4_iok.$$
fi
grep -q 'config RS4_IOSCHED_DEFAULT_NONE' "$IOK" || die "iosched Kconfig insert failed"
if ! grep -q 'config RS4_GPU_SKI' "$MSK"; then
  sed '$d' "$MSK" > "$MSK.new"
  cat >> "$MSK.new" <<'EOKC'

config RS4_GPU_SKI
	bool "Samsung /sys/kernel/gpu interface over the MediaTek GED/gpufreq modules"
	depends on MODULES && SYSFS
	help
	  Samsung's "SKI" GPU nodes (gpu_busy, gpu_clock, gpu_freq_table,
	  gpu_max_clock, gpu_min_clock, ...), served from the helpers the
	  stock mtk_gpu_hal and mtk_gpufreq_wrapper modules export. One UI's
	  Game Optimizing Service reads them for GPU monitoring.

endmenu
EOKC
  mv "$MSK.new" "$MSK"
fi
grep -q 'config RS4_GPU_SKI' "$MSK" || die "misc Kconfig insert failed"
say "Kconfig += CPU_FREQ_LIMIT RS4_BALANCE RS4_PASS_THROUGH RS4_IOSCHED_DEFAULT_NONE RS4_GPU_SKI"

# ── 4. elevator.c: an early return in elevator_get_default() ──────────────────
if ! grep -q 'CONFIG_RS4_IOSCHED_DEFAULT_NONE' "$ELV"; then
  awk '{print} /^static struct elevator_type \*elevator_get_default\(struct request_queue \*q\)/ && !d {f=1; next} f && /^\{/ {print "\tif (IS_ENABLED(CONFIG_RS4_IOSCHED_DEFAULT_NONE))\n\t\treturn NULL;\t/* rs4: default to none */\n"; f=0; d=1}' "$ELV" > "$ELV.new" && mv "$ELV.new" "$ELV"
fi
[[ "$(grep -c 'CONFIG_RS4_IOSCHED_DEFAULT_NONE' "$ELV")" == 1 ]] || die "elevator.c insert failed"
say "elevator.c: default none (when CONFIG_RS4_IOSCHED_DEFAULT_NONE)"

say "rs4 set applied (KMI-safe)"
