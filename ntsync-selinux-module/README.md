# ntsync SELinux enabler (Winlator/Wine)

A Magisk / KernelSU-Next / KoWSU module that opens the SELinux gate on `/dev/ntsync`
so apps (Winlator/Wine, which run as `untrusted_app`) can use the in-kernel NT-sync
backend. The kernel provides the node; this module labels it and adds the allow rule.

**Requires a rooted device + a kernel that provides `/dev/ntsync`** (built with
`CONFIG_NTSYNC` — Riza Kernel v4+). On the non-root **vanilla** kernel there's no
root manager to load this, so vanilla users need the rule baked into the ROM instead.

## What it does
- `sepolicy.rule` — creates a dedicated `ntsync_device` type and allows
  `untrusted_app` / `isolated_app` to `open`/`ioctl` a `chr_file` of that type.
  Loaded into the live policy at boot by the root manager (no ROM rebuild).
- `post-fs-data.sh` + `service.sh` — relabel `/dev/ntsync` to `ntsync_device` at
  boot (early + a late retry). Scoped: only this node gets the new label.

## Install
1. Flash the Riza Kernel (ksunext or kowsu) so `/dev/ntsync` exists and you have root.
2. Install `ntsync-selinux-module-*.zip` in the Magisk or KernelSU-Next/KoWSU manager.
3. Reboot.

## Verify (Termux + su, or adb)
```sh
ls -Z /dev/ntsync        # -> u:object_r:ntsync_device:s0
getenforce               # Enforcing (expected)
```
Then launch Winlator with its ntsync backend enabled. If it still can't open the
node, capture the denial and check the domain it actually runs in:
```sh
su -c 'dmesg | grep -i "avc:.*ntsync"'      # or: logcat -b all | grep ntsync
```
The `scontext=` in the denial is the app domain — if it's something other than
`untrusted_app*`/`isolated_app` (rare), add an `allow` line for it to `sepolicy.rule`.

## Notes
- Install log: `/data/adb/modules/ntsync_selinux/ntsync-selinux.log`.
- It bypasses `neverallow` (that's why it needs root) — fine on a personal device;
  the ROM-side rule is the cleaner path for wide distribution and covers vanilla.
- Harmless on kernels without `/dev/ntsync` (the relabel is skipped).
