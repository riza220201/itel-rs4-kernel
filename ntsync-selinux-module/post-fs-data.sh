#!/system/bin/sh
# Relabel /dev/ntsync to the ntsync_device type created by sepolicy.rule, so the
# allow rules apply. The policy (sepolicy.rule) is loaded by Magisk/KernelSU BEFORE
# post-fs-data, so the type exists by the time this runs. service.sh retries later
# as insurance. Runs early; safe no-op on kernels without /dev/ntsync.
MODDIR=${0%/*}
LOG="$MODDIR/ntsync-selinux.log"

{
  echo "=== ntsync-selinux post-fs-data $(date) ==="
  if [ -e /dev/ntsync ]; then
    if chcon u:object_r:ntsync_device:s0 /dev/ntsync 2>&1; then
      echo "relabeled /dev/ntsync -> ntsync_device"
    else
      echo "chcon failed here (type may load a hair later) — service.sh will retry"
    fi
    ls -Z /dev/ntsync 2>&1
  else
    echo "/dev/ntsync not present — kernel has no CONFIG_NTSYNC; nothing to do"
  fi
} > "$LOG" 2>&1
