# PLAN.md — v6 release planning

> Status: **PLANNING.** v5 (`3c88c35`) is the current release. Nothing here is
> committed to v6 until it meets the qualification bar in §2 and the operator
> picks the scope in §4.

---

## 1. Where v5 left off

v5 = Reflex CPUFreq governor across all flavors, on GKI **5.10.260**
(`common` @ `af99d873f`), each KMI-clean.

| flavor | root | hiding | `uname -r` |
|---|---|---|---|
| vanilla | — | — | `5.10.260-Riza-vanilla` |
| ksunext | KernelSU-Next v3.3.0 (33219) | SusFS v2.2.0 | `5.10.260-Riza-ksunext` |
| kowsu | KoWSU (KOWX712, 32579) | own | `5.10.260-Riza-kowsu` |

All carry BORE + ntsync + Reflex + perf/network tuning (`fq` default qdisc).

**Uncommitted / unreleased since v5:**

- `config/droidian.fragment` + a **fourth `droidian` variant** in `build.sh` —
  built (`out/droidian/`), never released. Adds `USER_NS`, `PID_NS`, `DEVTMPFS`,
  `VT` and bakes `module_blacklist=…` into `CONFIG_CMDLINE` so the Droidian port
  survives a foreign `vendor_boot`.
- `.github/` — CI workflow, held back at v3 because the PAT lacked `workflow` scope.
- `ntsync-selinux-module/` — Magisk module labelling `/dev/ntsync`; superseded on
  any ROM that bakes the sepolicy, still needed on ROMs that don't.
- `backup/`, `recreate-releases.sh`, `release-v{3,4,5}.sh` — local release tooling.

**Note:** the 2026-08-03 session did **not** change the kernel. ksunext was
rebuilt from already-pinned sources. v6 is therefore justified by the new responsibility in §3 — and, since
2026-09-03, by the GKI LTS bump (§4 row 10) — not by new kernel
features. If neither is wanted, "no v6 yet" is a legitimate answer.

---

## 2. v6 candidate qualification — the bar

A change ships in v6 only if it clears **all** of these. Each rule exists
because this project already paid for it.

### 2.1 The KMI gate is non-negotiable
`module_layout == 0x7c24b32d`, **198/198**, 0 CRC mismatches, verified by
`build.sh`'s own gate — not by inspection. A KMI-broken kernel boots no ROM on
this device. Anything needing new per-task/mm/inode state must be packed into
`ANDROID_KABI_RESERVE` slots via `ANDROID_KABI_USE()` (the BORE pattern), or it
does not ship.

### 2.2 It must not break recovery
Recovery shares the `boot` kernel — there is no dedicated recovery partition.
Built-in `CONFIG_ZRAM` bricks OrangeFox on this SoC, and it was *silently inert*
until `ZSMALLOC=y` satisfied its dependency and switched it on for the first
time. **Any config addition must be checked for what it transitively enables**,
and any change touching early mm/tmpfs gets an explicit recovery-boot test.

### 2.3 On-device proof, not gate-clean
A passing KMI gate proves modules *load*. It does not prove the feature works,
and it never proves the device is usable. Precedents:
- `ksunext` shipped only after root **and** hiding were confirmed on hardware.
- crDroid's step 30 passed artifact verification *and* a zero-denial sweep, then
  force-closed an app in a public release — because the failure mode emitted no
  denial at all.

⇒ Every v6 feature needs a **written functional check executed on hardware**
before release. "It compiles and gates clean" is a candidate, not a release.

### 2.4 Correctness must be validatable here
If a change's failure mode is silent data corruption or a subtle fast-path bug
we cannot exercise, it does not ship. **BBRv3 was descoped on exactly this
ground**: KMI-viable, module written, but TCP correctness is not observable from
the build, the gate, or a "does the phone have internet" flash test.

### 2.5 Reproducible
Every out-of-tree source pinned by **SHA** in `sources.lock`, not by branch. A
branch tip that moves silently changes what users get and desynchronises the
installer banner from the kernel (already a near-miss at v3).

### 2.6 Root variants: manager pairing verified
KernelSU-family kernels bind a manager they *pair* with — not merely "manager
≥ kernel". The kowsu 32525-vs-32579 mismatch reached users as "Not installed"
on a perfectly good build. Any root variant must state its exact manager build
and have it confirmed on hardware.

### 2.7 Honest release notes
Claim only what was verified. No "works" for anything gate-only. Known issues
stay in. (v2.2's "PC-less unbrick" claim had to be publicly retracted.)

---

## 3. New responsibility: the device kernel package

The clean-room work in `~/itel-rs4-devicetree` means
**`device_itel_S666LN-kernel` must now be ours too**, and this project is its
natural home:

- it already produces `Image.gz`
- it already holds the 198 `vendor_dlkm` `.ko` for the KMI gate
- it is where a custom `mali_kbase.ko` would come from

Contents (staged and verified at `~/itel-rs4-devicetree/.build/kernelpkg/`,
71 MB, extracted from **stock rev 28**):

```
dtb/           1 file (sha ec545bea…)
dtbo.img       8,388,608
ramdisk/       206 .ko + modules.{alias,dep,load,load.recovery,softdep}
vendor_dlkm/   198 .ko + modules.{alias,dep,load,softdep}   KMI 0x7c24b32d ×198
Image.gz       ← ours, per variant
```

Every byte except `Image.gz` is stock itel/MediaTek output, so this is
repackaging, not authoring. **Open question for the operator:** publish it as a
separate repo (recommended — 235 MB is too heavy for the device tree, and it
churns on a different cadence), or fold it in.

---

## 4. v6 candidates, assessed against §2

| # | candidate | §2 status | cost | verdict |
|---|---|---|---|---|
| 1 | ~~**`droidian` variant** (4th flavor)~~ | **REMOVED from this plan 2026-09-03 (operator).** Droidian is the PARENT project — this kernel project exists because of it, and the KMI produce-and-verify mechanism came FROM it. Releasing the variant belongs to `~/droidian-s666ln`, which owns the boot test and the field use. Carrying it here inverted the dependency. | — | **not this project's to ship** |
| 2 | **Publish `device_itel_S666LN-kernel`** | n/a (no kernel change) | low, mechanical | **strong** — unblocks the device tree |
| 3 | **`.github/` CI** | n/a | needs a `workflow`-scope PAT | **easy include** |
| 4 | **zram as a loadable module** | §2.2 is the whole point — built-in bricks recovery | small | **good** — restores a feature killed at v2 |
| 5 | **BORE refresh** (bore5.1.0 → newer) | KABI pattern already proven | small | **good**, wants a smoothness check |
| 6 | **MGLRU** | 🔴 **RE-ASSESSED 2026-09-03 — worse than "needs KABI packing", see below** | large | **effectively blocked** |

> 🔴 **MGLRU IS BLOCKED ON THIS DEVICE, AND THE KMI GATE CANNOT TELL YOU THAT.**
> Three findings, each measured, that compound:
>
> **1. `struct lruvec` has ZERO `ANDROID_KABI_RESERVE` slots.** Its body is fully
> packed — lists, anon_cost, file_cost, nonresident_age, refaults, flags, pgdat.
> mmzone.h's 4 reserves are at lines 586-589, in a different struct entirely, and
> `mm_struct` has 1. So MGLRU's per-lruvec state cannot be added without GROWING
> the struct; there is no padding to claim.
>
> **2. `lruvec` is embedded BY VALUE in `pglist_data`** (`struct lruvec __lruvec;`,
> mmzone.h:98) with fields after it. Grow lruvec and every later field in
> `pglist_data` shifts.
>
> **3. Four STOCK vendor modules read exactly that, and we cannot rebuild any of
> them** — they are Transsion/MTK binaries at vermagic `5.10.237`, no source:
>
> ```
> memfusion.ko     contig_page_data  get_mem_cgroup_from_mm  lookup_page_ext
> zsmalloc.ko      contig_page_data
> trace_mmstat.ko  contig_page_data
> zram.ko          lookup_page_ext
> ```
>
> That is the memory subsystem: the zram stack plus Transsion's RAM expansion —
> the feature giving this device 6.3 GB of swap. A shifted offset there is silent
> corruption, not a clean failure.
>
> 🔑 **AND THE GATE IS STRUCTURALLY BLIND TO IT.** `module_layout`'s CRC is
> computed from its own signature — `struct module`, `modversion_info`,
> `kernel_param`, `kernel_symbol`, `tracepoint` (kernel/module.c:4825). It does
> not reference `lruvec` or `mm_struct`. **A kernel with a grown lruvec would
> reproduce 0x7c24b32d, pass §2.1, and still be ABI-incompatible with four
> shipped modules.** This is the project's own recurring failure shape —
> a criterion that measures the wrong layer reads as a pass forever — sitting
> underneath its single most trusted gate.
>
> Reviving MGLRU therefore needs a design that keeps per-lruvec state OUT of
> `lruvec` (a side table keyed by node/memcg), plus an ABI check that actually
> covers mm layout. Not a packing exercise.
| 7 | **Mali r54p1 `mali_kbase.ko`** | builds, KMI-clean, **probes on hardware** — but the r32p1 UMD is rejected (`Stride 72`), so it is unusable until a matching UMD exists | done | **do NOT ship as default.** Optional artifact at most |
| 8 | BBRv3 | ✗ §2.4 | large | **stays descoped** |
| 9 | SUS_SU / KPM | assessed and dropped (SUS_SU deprecated ecosystem-wide; KPM = SukiSU-only) | — | **no** |
| 10 | **GKI LTS bump** 5.10.260 -> current `android12-5.10-lts` | ADDED 2026-09-03. Was missing from this table entirely — the only candidate carrying security content. Self-verifying: `device.conf` refuses to build unless `module_layout` reproduces `0x7c24b32d`. | medium — see the coupling note | **strong, and belongs FIRST** |

> ⚠ **The bump is no longer just a kernel bump on this device.** Since r54p1
> shipped we build our own `mali_kbase_mt6789.ko` against our own kernel, so
> every bump drags the GPU driver with it: rebuild the kbase
> (`~/itel-rs4-devicetree/tools/kernel-patches/build-mali-kbase.sh`), re-verify
> the DVFS bit out of the disassembly, re-verify on hardware. Mechanical, but
> real — and it is the argument for bumping DELIBERATELY AND RARELY rather than
> tracking LTS closely. It also means the bump must come FIRST in any release
> that also touches BORE or the variants, or they get tested twice.
>
> Row 7's r54p1 verdict below ("do NOT ship as default") is STALE — it shipped,
> and the device reports `r54p1-12eac0`. Row 2 is done; row 4 is moot (stock's
> `zram.ko` already ships and the device runs 6.3 GB of zram via `memfusion`).

### Proposed v6 scope (operator decides)

**Ship:** 1 + 2 + 3 + 4 + 5 — a maintenance/consolidation release. All low-risk,
all already-proven patterns, and it clears the backlog that has been sitting
uncommitted since v5.

**Defer:** 6 (MGLRU) to its own release, where it can get the attention a KABI
change deserves. **Exclude:** 7, 8, 9.

Rationale: v6 as consolidation lets the device-tree work proceed (needs #2)
without coupling it to a risky kernel feature. MGLRU as v7 gets a clean blast
radius.

---

## 5. Release gate for v6

- [ ] All flavors build; KMI gate **198/198 @ 0x7c24b32d** each
- [ ] `sources.lock` SHAs unchanged or deliberately bumped, version-drift check passes
- [ ] **Recovery boots** on each flavor (§2.2)
- [ ] vanilla: boots, no regressions
- [ ] ksunext: root binds with **KSU-Next v3.3.0 (33219)**, SusFS hiding confirmed
- [ ] kowsu: root binds with the **current KOWX712** manager (§2.6 — re-check the pin; KOWX712 moves `master` fast)
- [ ] zram loads as a module and recovery still boots
- [ ] `device_itel_S666LN-kernel` published, device tree syncs against it
- [ ] Release notes claim only what was verified (§2.7)

---

## 6. Parked, with reasons

- **BBRv3** — `tcp_bbr3.c` + the KMI-viability proof are in `.build/bbrv3-src/`.
  Revive only with a proven community android12-5.10 backport *and* real network
  testing.
- **SukiSU + KPM** — viable via the `ShirkNeko/GKI_KernelSU_SUSFS` recipe
  (SukiSU-Ultra + ShirkNeko/susfs4ksu + **SukiSU_patch** + a `patch_linux`
  post-build step). Dropped: niche, and ksunext already gives root + full SusFS
  hiding.
- **Mali r54p1 kbase** — kernel half done and hardware-proven. Blocked on the
  UMD, which needs AIDL gralloc, which is a *vendor* property (an Android 14+
  rebuild does not supply it). See `~/itel-rs4-devicetree/notes/JOURNAL.md`.
- **musb USB-gadget flap** — audited and closed: not kernel-tied (same kernel is
  stable on userdebug, flaps only on user builds). ROM/HAL-side.
