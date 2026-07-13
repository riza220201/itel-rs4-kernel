# Riza Kernel — Itel RS4 (S666LN / MT6789)

Custom GKI **5.10** kernels for the Itel RS4 (MediaTek MT6789 / Helio G99), plus
the build tooling I use to make them. They run on **stock firmware and custom
ROMs** — same kernel, any ROM.

Maintainer: **Riza** · device: itel-S666LN · base: MillenniumOSS `android12-5.10-lts`.

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
| **vanilla** | performance + network, no root | `5.10.258-Riza-vanilla` |
| **ksu** | vanilla + KernelSU + SusFS | `5.10.258-Riza-ksu` |

Both ship as an **AnyKernel3 zip** (flash in OrangeFox — swaps only the kernel,
keeps your ROM's ramdisk, works on any ROM) and a **prebuilt `boot.img`** (direct
antumbra DA flash, stock firmware only).

**What's tuned:**
- net — TCP BBR (default) + fq / fq_codel / CAKE + WireGuard
- storage — BFQ + Kyber I/O schedulers, all CPU governors
- memory — ZRAM with zstd/lz4
- ksu build — KernelSU **v3.2.5** + SusFS v2.2.0 (root + hiding)

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

**KSU build:** install the KernelSU manager **exactly v3.2.5**
([release](https://github.com/tiann/KernelSU/releases/tag/v3.2.5),
`KernelSU_v3.2.5_32525-release.apk`). Any other version and the manager/driver
versions mismatch and `su` won't work.

## Building it yourself

```sh
./build.sh <vanilla|ksu> [--pack]
```

`--pack` also produces the boot.img + AnyKernel3 zip. A build is one full-LTO link
(~20-30 min; it's heavy — want swap on a 14 GB box). You'll need the kernel source
(MillenniumOSS android12-5.10-lts), the AOSP `clang-r416183b` toolchain, your
device's stock `boot.img`, and the stock `vendor_dlkm` modules for the KMI check —
paths are set at the top of `build.sh` (default to a sibling checkout, all
overridable by env var). Adding a feature = drop `CONFIG_*` into
`config/performance.fragment` or `config/network.fragment`; if it breaks the KMI
gate, back it out (the gate is right).

Layout: `build.sh` (build + KMI gate), `package.sh` (boot.img + zip),
`apply-ksu-susfs.sh` (KernelSU + SusFS), `lib/kmi_check.py` (the 198-module
cross-check), `config/*.fragment`, `anykernel/` (bundled AnyKernel3).

## Credits

Standing on other people's work:
- **MillenniumOSS** — the `android12-5.10-lts` source
- **KimelaZX / KimelaZPrjkt** — Itel S666LN device trees + OrangeFox
- **tiann** — KernelSU · **simonpunk** — SusFS · **osm0sis** — AnyKernel3

Bug reports welcome — bring logs.
