#!/system/bin/sh
# DS4 over Bluetooth — capture for the Riza Kernel. Needs root.
#  1. connect the controller over Bluetooth
#  2. run:   su -c 'sh /sdcard/Download/ds4diag.sh'
#  3. when it says PRESS, press buttons and move both sticks until it says done
#  4. send back the folder /sdcard/ds4diag
S=${1:-10}
O=/sdcard/ds4diag
rm -rf $O; mkdir -p $O
M=0
mountpoint -q /sys/kernel/debug || { mount -t debugfs debugfs /sys/kernel/debug && M=1; } \
  || { echo "!! cannot mount debugfs"; exit 1; }
D=$(ls -d /sys/kernel/debug/hid/*:054C:* 2>/dev/null | tail -n 1)
[ -n "$D" ] || { echo "!! no Sony controller found: connect it over Bluetooth first"; exit 1; }
{ echo "$D"; uname -a; getprop ro.build.display.id; } > $O/device.txt
cat $D/rdesc > $O/rdesc.txt
getevent -lp > $O/input-devices.txt 2>&1
echo ">>> PRESS BUTTONS AND MOVE BOTH STICKS NOW, for $S seconds"
timeout $S cat $D/events > $O/hid-events.txt 2>&1 &
timeout $S getevent -lt > $O/getevent.txt 2>&1
wait
dmesg | grep -i -E 'sony|054c|uhid|hid' | tail -n 100 > $O/dmesg-hid.txt
[ $M = 1 ] && umount /sys/kernel/debug
echo ">>> done: send the folder $O"
ls -l $O
