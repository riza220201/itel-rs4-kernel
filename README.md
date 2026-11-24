# Ujang-X-Hinojoburi — itel RS4 (S666LN / MT6789) on android16-6.12

Custom GKI **6.12** kernels for the itel RS4 (MediaTek MT6789 / Helio G99): the RS4's move
from `android12-5.10` to `android16-6.12`, the kernel generation every other MT6789 phone
now ships.

Maintainer: **Riza** · device: itel-S666LN · base: Google GKI `android16-6.12`
(6.12.38, `KMI_GENERATION=5`) with the build-and-gate pipeline of the Rival Abadi kernel
(Infinix HOT 60 Pro+, same SoC).

> **Branches:** `6.12` (this one, the default) · `5.10` — the Riza Kernel line (v1–v11,
> `5.10.272-Riza-<variant>`) for the RS4's current ROMs.

> **Status: in development.** Both variants build and pass the three-layer gate below.
> ⚠ **Not a drop-in for today's RS4 ROMs.** Every RS4 ROM so far ships 5.10 vendor modules,
> which cannot load on a 6.12 kernel. This kernel pairs with a 6.12 vendor side: MediaTek's
> own 6.12 driver tree for MT6789, built from source for the RS4. Use the `5.10` branch for
> stock firmware and the current custom ROMs.

## Variants

| variant | what | `uname -r` |
|---|---|---|
| **vanilla** | BORE 7.0.0 + Reflex 0.4.0 + ntsync + ADIOS 3.3.0 + Kcompressd 0.5 + le9uo 1.14 + `s666ln_balance` + BBRv3 / fq / CAKE, no root | `6.12.38-Ujang-X-Hinojoburi` |
| **ksunext** | vanilla + KernelSU-Next **33553** (`v3.4.2-198-g7ccf6147`, uapi 6) + SusFS **v2.4.0** | `6.12.38-ZUjang-X-HinojoburiZ` |

The KernelSU-Next build is the same KernelSU-Next as the `5.10` branch's v11, so the manager
already installed for it (CI build `v3.4.2-198-g7ccf6147`, versionCode 33553) binds this
kernel as well.

**What's in it:**
- **`s666ln_balance`** — the RS4's own balanced CPU policy (the 5.10 `rs4_balance`, v7, with
  its RS4-measured numbers), as `freq_qos` requests on top of the governor: a boot boost, a
  modest little-cluster floor while touching, and a screen-off cap (little 1.2 GHz, big
  1.0 GHz) that any key or touch lifts at once. On 6.12 the touch floor is a direct `freq_qos`
  request, and the screen-off cap arms only after `lcd-backlight` has been seen lit, so a stale
  0 can never cap a phone in use. Tunables: `/sys/module/s666ln_balance/parameters/`.
- sched — **BORE 7.0.0**, KMI-packed into `task_struct`'s reserved slots; `sysctl
  kernel.sched_bore=0` turns it off live. Built-in **sched_ext**.
- cpufreq — **Reflex 0.4.0** (`latency_weight` 300).
- compat — **ntsync** (`/dev/ntsync`) for Wine / Winlator.
- memory and storage — MGLRU, **Kcompressd 0.5**, **le9uo 1.14** (dormant by default),
  **ADIOS 3.3.0** + BFQ + Kyber + mq-deadline.
- net — **BBRv3** (default, KMI-safe: no `tcp_sock` size change) + fq (default qdisc) + CAKE
  + Westwood / Vegas / H-TCP + TTL/HL targets.
- compiler — Neutron Clang 24 (`gendwarfksyms` fixed for it, so Wi-Fi's `cfg80211` loads).

On 6.12 two pieces of the `5.10` branch's RS4 set are native and not carried: Samsung's
`/sys/kernel/gpu` comes from MediaTek's own 6.12 GED, and `cpufreq_limit` is a module of the
6.12 tree.

## The gate

Nothing ships unless every module the RS4 loads would load on it:

```
layer 1  symbol CRCs & module_layout   170 RS4 modules (159 first stage + 11 GPU) + 81 system_dlkm
layer 2  protected exports (MODULE_SIG_PROTECT) in vmlinux = 0
layer 3  2,661 RS4 imports = 2,052 vmlinux + 609 siblings + 0 UNRESOLVED · 0 NOT permitted
```

The RS4 modules are MediaTek's 6.12 tree built from source against the stock GKI
(`module_layout 0xe976b219`) plus 13 Transsion binaries that have no source. The three
layers' negative-control self-tests run without a kernel:

```bash
./test/kmi-gate-selftest.sh
./test/protect-gate-selftest.sh
./test/import-gate-selftest.sh
```

## Build & package

```bash
./build.sh vanilla                # + patches/series + config/vanilla_defconfig + brand
./build.sh ksunext                # vanilla + KernelSU-Next 33553 + SusFS v2.4.0
./build.sh vanilla --gate-only    # re-gate without rebuilding
./package.sh vanilla              # AnyKernel3 zip + repacked boot.img
./package.sh ksunext
```

`build.sh` refuses a kernel source that drifted off `sources.lock`, asserts the release
string in `kernel.release` and the `Image` banner, and checks every patch's config switch and
probe symbol in `System.map`. Device facts (names, module_layout, reference sets, kernel
format, release tags) live in `device.conf`.

## Layout

```
build.sh                  build + 3-layer gate (+ branding, feature check, per-variant staging)
apply-mods.sh             applies patches/series to the pinned tree — strict, no fuzz
apply-ksunext-susfs.sh    KernelSU-Next (pershoot dev-susfs) + SusFS, ksunext only
patches/                  one patch per modification, provenance in each header
config/                   vanilla_defconfig (all variants) + ksunext_defconfig
package.sh                AnyKernel3 zip + boot.img repack + ash execution self-test
sources.lock              pinned kernel ref, KSU/SusFS commits, toolchain versions, and why
device.conf               device facts and the per-variant release tags
lib/                      the three gate layers
tools/                    toolchain fetch, reference-set harvest
```

## Credits & contributors

GKI and kleaf are Google's; the MT6789 driver tree is MediaTek's. BORE, Reflex, ADIOS,
Kcompressd-Unofficial and le9uo are firelzrd's (Kcompressd after Qun-Wei Lin, MediaTek);
ntsync is Elizabeth Figura's (CodeWeavers). KernelSU-Next, pershoot's `dev-susfs`,
simonpunk's SusFS. Neutron Clang is Neutron-Toolchains'. AnyKernel3 is osm0sis'. The
balance policy's ideas come from SuiKernel (LoggingNewMemory). The pipeline and gate are
the Rival Abadi kernel's.

**Contributors:**
* **Riza** (`riza220201`) — maintainer & project lead
* **Claude Opus** (Anthropic) — co-author (GKI 6.12 pipeline and 3-layer gate, the RS4 6.12 bring-up)
* **Gemini Argon** (Google DeepMind) — co-author (Neutron Clang 24 Kleaf integration and the `gendwarfksyms` Wi-Fi fix, BORE 7.0.0 / Reflex 0.4.0 updates, AnyKernel3 GKI fix and self-test)
