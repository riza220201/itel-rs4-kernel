#!/system/bin/sh
# Install-time messaging (Magisk / KernelSU-Next / KoWSU all source this).
SKIPUNZIP=0

ui_print " "
ui_print "  ntsync SELinux enabler (Winlator/Wine)"
ui_print "  --------------------------------------"
ui_print "  Labels /dev/ntsync and allows apps to use it."
ui_print " "

if [ -e /dev/ntsync ]; then
  ui_print "  [+] /dev/ntsync detected on the running kernel — good."
  ui_print "      Current label: $(ls -Z /dev/ntsync 2>/dev/null | awk '{print $1}')"
else
  ui_print "  [!] /dev/ntsync NOT found on the current kernel."
  ui_print "      This module only does something on a kernel built with"
  ui_print "      CONFIG_NTSYNC (Riza Kernel v4+: ksunext / kowsu / vanilla)."
  ui_print "      Installing anyway — it activates once you boot such a kernel."
fi

ui_print " "
ui_print "  After reboot, verify:  ls -Z /dev/ntsync"
ui_print "  should read  u:object_r:ntsync_device:s0"
ui_print " "
ui_print "  NOTE: the kernel only provides the node + this opens the gate."
ui_print "  Winlator/Wine must also be built to USE the ntsync backend."
ui_print " "

# Nothing to place on the filesystem; scripts + sepolicy.rule are handled by the root manager.
set_perm_recursive "$MODPATH" 0 0 0755 0644
