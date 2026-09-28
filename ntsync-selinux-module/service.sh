#!/system/bin/sh
# Late-boot retry of the relabel, in case /dev/ntsync appeared late or was
# relabeled by something after post-fs-data. Idempotent.
MODDIR=${0%/*}
LOG="$MODDIR/ntsync-selinux.log"

# wait for boot to complete (bounded), then re-apply
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 60 ]; do
  sleep 2; i=$((i+1))
done

if [ -e /dev/ntsync ]; then
  chcon u:object_r:ntsync_device:s0 /dev/ntsync 2>/dev/null
  {
    echo "=== ntsync-selinux service (boot_completed) $(date) ==="
    ls -Z /dev/ntsync 2>&1
  } >> "$LOG" 2>&1
fi
