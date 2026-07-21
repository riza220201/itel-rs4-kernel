# Riza Kernel — Itel RS4 (S666LN / MT6789)

Custom GKI **5.10** kernels for the Itel RS4 (MediaTek MT6789 / Helio G99), plus
the build tooling I use to make them. They run on **stock firmware and custom
ROMs** — same kernel, any ROM.

Maintainer: **Riza** · device: itel-S666LN · base: Google GKI `android12-5.10-lts`
(pristine `kernel/common`, vendored as a submodule).

## The hard part: KMI

On this device every ROM reuses the MediaTek vendor partition, and its 198
prebuilt `vendor_dlkm` modules only load against one exact kernel ABI —
`module_layout = 0x7c24b32d`. Get that wrong and nothing boots: no storage, no
display, no anything. Most "custom kernels" for MTK dodge this by force-loading
modules; I don't. I build from MediaTek's own stock config (CFI + full LTO +
MODVERSIONS — that combination is what reproduces the ABI) and every build is
**hard-gated against all 198 real vendor modules**. If a build would break even
one module's CRC, the tool refuses to package it. So the modules load natively,
zero force-load, and it boots stock or custom ROMs the same.

## Variants

| variant | what | `uname -r` |
|---|---|---|
| **vanilla** | performance + network + BORE, no root | `5.10.260-Riza-vanilla` |
| **ksunext** | vanilla + KernelSU-Next + SusFS | `5.10.260-Riza-ksunext` |
| **kowsu** | vanilla + KoWSU (own hiding, no SusFS) | `5.10.260-Riza-kowsu` |

All three ship as an **AnyKernel3 zip** (flash in OrangeFox — swaps only the
kernel, keeps your ROM's ramdisk, works on any ROM) and a **prebuilt `boot.img`**
(direct antumbra DA flash, stock firmware only).

**What's tuned (all variants):**
- sched — **BORE** (Burst-Oriented Response Enhancer) for snappier foreground
  under load; on by default, flip it off live with `sysctl kernel.sched_bore=0`
  (no reflash). Experimental on this MTK EAS SoC.
- compat — **ntsync** (`/dev/ntsync`): mainline's NT synchronization driver
  (semaphores + mutexes + events + wait-all/wait-any) backported to 5.10, for
  **Wine / Winlator** — it backs Windows sync objects with in-kernel objects
  instead of the eventfd esync/fsync, cutting sync overhead for Windows games
  under emulation. A self-contained leaf misc driver (KMI-inert). Note: exposing
  the node to apps needs a **ROM sepolicy** rule for `/dev/ntsync`, and a Winlator
  build that uses the ntsync backend — the kernel just provides the node.
- net — TCP BBR (default) + fq / fq_codel / CAKE + WireGuard + TTL/HL targets
  (normalize TTL for tethering)
- storage — BFQ + Kyber I/O schedulers, all CPU governors
- memory — compressors built in (zstd / lz4 / lzo-rle) for zram, but **ZRAM is
  NOT compiled into the kernel** — on this device a built-in `CONFIG_ZRAM=y`
  bricks OrangeFox recovery (ofox runs from /tmp tmpfs and, with no recovery
  partition, shares the `boot` kernel; built-in zram's early mm collides with it).
  Load zram as a KSU-Next kernel module at normal boot instead — recovery never
  loads modules, so it stays safe.
- **ksunext** — KernelSU-Next **v3.3.0** + SusFS v2.2.0 (root + full hiding)
- **kowsu** — KoWSU (KOWX712 KernelSU), a lean KernelSU-Next fork with its own
  kernel-side hiding (per-app umount + selinux hide). No SusFS — KoWSU's tree is
  restructured and SusFS doesn't target it, so this is the standalone build.

> On the root variant: earlier releases used official KernelSU because SusFS had
> no clean pairing with the restructured KSU-Next source on this 5.10 tree. The
> current `ksunext` moves to the **latest KernelSU-Next (v3.3.0)** by taking the
> **Wild KSU** route — pershoot's `dev-susfs` branch (KSU-Next with SusFS in-driver)
> plus the stock SusFS v2.2.0 kernel patch with pershoot's extension cherry-picks,
> the same combination WildKernels ships. It verifies against the vendor ABI
> (198/198), so official KernelSU is retired. KoWSU stays as the no-SusFS option.

## Flashing

No reliable fastboot on this thing, so it's OrangeFox (zip) or antumbra (MTK DA).
It's A/B (Virtual A/B).

- **AnyKernel3 zip** — flash in OrangeFox, works on any ROM. Reads the boot.img on
  your active slot, swaps in the kernel, keeps your ramdisk. `IS_SLOT_DEVICE=auto`
  (don't force it — that's what throws "unable to determine slot").
- **Prebuilt `boot.img`** — stock firmware only (it carries the stock ramdisk).
  Write to `boot_a`/`boot_b` with antumbra. Don't use on a custom ROM.

Keep your current/stock `boot.img` around to restore — flashing only touches the
kernel, so a bad flash is boot-only and easy to recover.

**ksunext build:** install the **KernelSU-Next v3.3.0** manager (from
[KernelSU-Next/KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next)
releases). The kernel reports version **33219**; the manager must be at least that
or `su` is denied.

**kowsu build:** the kernel reports KoWSU version **32579** and pairs with the
**matching** [KOWX712/KernelSU](https://github.com/KOWX712/KernelSU) manager
(`v3.2.5-54-gcfac3be3`, i.e. the current build). Install *that* manager — a
mismatched/older one shows "Not installed" (KernelSU only binds a manager it pairs
with, not merely "≥"). This tracks KOWX712's fast-moving `master`; if a newer manager
stops binding, the kernel needs re-bumping to match (open an issue).

## Building it yourself

Clone with the kernel source submodule (Google GKI `android12-5.10-lts`) + fetch
the Clang toolchain (1.4 G, git-ignored — not vendored):
```sh
git clone --recursive https://github.com/riza220201/itel-rs4-kernel
# already cloned? →  git submodule update --init --depth 1 common
# bump to the latest LTS tip →  git submodule update --remote --depth 1 common
./fetch-toolchain.sh          # pulls clang-r416183b into ./toolchain/
# drop your device's stock boot.img at ./boot.img, then:
./extract-config.sh           # extracts the base config from boot.img → .build/ikconfig/
./build.sh <vanilla|kowsu|ksunext> [--pack]
```

The build reads **`device.conf`** for the one make-or-break per-device value —
`MODULE_LAYOUT`, the KMI CRC your vendor blobs demand — and **refuses to start**
until it's a valid CRC (it tells you how to get yours:
`modprobe --dump-modversions <vendor>.ko | awk '$2=="module_layout"{print $1}'`).
The core kernel itself is generic GKI — the KMI is reproduced by the config, so any
faithful `android12-5.10` source works.

`--pack` also produces the boot.img + AnyKernel3 zip. A build is one full-LTO link
(~20-30 min; it's heavy — want swap on a 14 GB box). The kernel source is the
`common` submodule; the Clang toolchain comes from `./fetch-toolchain.sh`; the base
config comes from **your own stock boot.img** via `./extract-config.sh` (all
git-ignored, nothing device-specific committed). Adding a feature = drop `CONFIG_*`
into `config/performance.fragment` or `config/network.fragment`; if it breaks the
KMI gate, back it out (the gate is right).

### Porting to another device

The tool is device-agnostic — everything device-specific lives in **`device.conf`**
(env vars override it per-run). To retarget:

1. **`MODULE_LAYOUT`** — set it to *your* device's KMI CRC (read it off any stock
   `vendor_dlkm/*.ko` with the `modprobe --dump-modversions` line above). The build
   refuses to start without a valid one.
2. **Stock kernel config** — the build composes on top of *your device's own stock
   kernel `.config`* (that's what carries the CFI + LTO + MODVERSIONS flags that
   reproduce your KMI). You don't hand-write it — you extract it:
   - **Get your stock `boot.img`.** Pull it from your device's stock firmware /
     factory package / OTA (or dump the `boot` partition on the device). Drop it at
     **`./boot.img`** (or point `BOOT_IMG=` at it).
   - **Run `./extract-config.sh`.** It runs `extract-ikconfig` on that boot.img and
     writes the config to **`.build/ikconfig/stock.config`** — which is exactly the
     default `STOCK_CONFIG` the build reads. So once it succeeds, you're done; no
     assignment needed. It aborts if the config lacks `CFI_CLANG=y` (wrong image).
   - **Where it's assigned:** `STOCK_CONFIG` defaults to `.build/ikconfig/stock.config`.
     If you keep your config somewhere else, set `STOCK_CONFIG="/path/to/your.config"`
     in `device.conf`.
   - *No boot.img?* If your device is already running and its kernel has
     `CONFIG_IKCONFIG_PROC`, `zcat /proc/config.gz` on the device gives the same config
     — save it as `.build/ikconfig/stock.config` (or point `STOCK_CONFIG` at it).
3. **`KERNEL_FMT`** — `gzip` / `lz4` / `raw`, matching how your stock boot.img stores
   the kernel (`magiskboot unpack boot.img` prints it). Wrong value → the repacked
   boot.img won't boot.
4. **Device identity** — `DEVICE_LABEL`, `DEVICE_SOC`, `DEVICE_NAMES` (AnyKernel3
   allowlist), `BRAND`. These drive the branding, installer banner, and release file
   names; all optional.
5. **`VENDOR_KO_DIR`** *(recommended)* — drop your stock `vendor_dlkm/*.ko` into
   `.build/vendor_dlkm/` (the default) for the full 198-module CRC cross-check. Without
   it the gate checks `module_layout` only and warns.

Everything else (`KERNEL_SRC`, `STOCK_CONFIG`, `BOOT_IMG`, `CLANG_DIR`) has a sane
default and is overridable in `device.conf` or via env.

Layout: `build.sh` (build + KMI gate), `package.sh` (boot.img + zip),
`extract-config.sh` (base config from boot.img), `device.conf` (per-device config),
`sources.lock` (pinned out-of-tree commit set — see below),
`apply-ksunext-susfs.sh` + `patches/ksunext-static.patch` (KernelSU-Next v3.3.0
Wild + SusFS), `apply-kowsu.sh` (KoWSU), `apply-bore.sh` +
`patches/bore-5.10-kmi.patch` (BORE, applied to every variant), `apply-ntsync.sh` +
`patches/ntsync-5.10.patch` (ntsync, applied to every variant), `lib/kmi_check.py`
(the 198-module cross-check), `config/*.fragment`, `anykernel/` (bundled
AnyKernel3). The root-variant sources are **SHA-pinned in `sources.lock`** (the KSU
side, SusFS, and KoWSU commits) and checked out into `.build/wildksu`,
`.build/susfs-wild`, `.build/kowsu-ksu`; the build verifies the reported KSU version
against the lockfile and dies on drift, so a moved upstream branch can't silently
change what a variant is.

**On BORE + KMI:** BORE needs per-task burst fields on `sched_entity`, which is
embedded in `task_struct` — adding fields there would change the layout and break
the vendor ABI. Instead the burst state is packed into `sched_entity`'s
`ANDROID_KABI_RESERVE` slots via `ANDROID_KABI_USE()`, which the genksyms pass
sees as the original reserved `u64` — so `module_layout` and every vendor CRC come
out byte-identical. The gate confirms it (198/198) on every build.

## Credits

Standing on other people's work:
- **Google / AOSP** — the GKI `android12-5.10-lts` `kernel/common` source
  (MillenniumOSS was the original base; upstream Google proved more stable here)
- **KimelaZX / KimelaZPrjkt** — Itel S666LN device trees + OrangeFox
- **KernelSU-Next** — KernelSU-Next · **pershoot** — Wild KSU (`dev-susfs`) ·
  **WildKernels** — the current KSU-Next + SusFS integration recipe
- **simonpunk** — SusFS · **tiann** — original KernelSU · **osm0sis** — AnyKernel3
- **KOWX712** — KoWSU · **firelzrd** — BORE scheduler
- **Elizabeth Figura / CodeWeavers** — the ntsync driver (mainline)

Bug reports welcome — bring logs.
