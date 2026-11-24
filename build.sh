#!/usr/bin/env bash
# build.sh — build a kernel variant for this device and gate it against the KMI.
#
#   ./build.sh vanilla            stock ACK + patches/series + KMI-safe fragments + brand
#   ./build.sh vanilla --stock    pure ACK, zero fragments (the control build)
#   ./build.sh ksunext            vanilla + KernelSU-Next + SusFS
#
# Flags:
#   --stock        no defconfig fragments at all. Use this for the first build on
#                  a new source branch: it measures ONE thing — whether that
#                  branch reproduces the device's KMI — instead of conflating it
#                  with whatever we changed.
#   --gate-only    skip the build, re-run the gates against the last outputs.
#   --jobs N       cap bazel's parallelism (RAM-bound boxes).
#
# The build system here is **kleaf/Bazel**, not `make` + `build.config`. Nothing
# from the itel RS4 project's build.sh transfers; only its discipline does.
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJ"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "== $*"; }

# ── Arguments ───────────────────────────────────────────────────────────────
VARIANT=""; STOCK=0; GATE_ONLY=0; JOBS=""; LTO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    vanilla|ksunext) VARIANT="$1" ;;
    --stock)         STOCK=1 ;;
    --lto)           shift; LTO="${1:-}" ;;
    --gate-only)     GATE_ONLY=1 ;;
    --jobs)          shift; JOBS="${1:-}" ;;
    *)               die "unknown argument: $1" ;;
  esac
  shift
done
[[ -n "$VARIANT" ]] || die "usage: ./build.sh <vanilla|ksunext> [--stock] [--gate-only] [--jobs N]"

# ── device.conf ─────────────────────────────────────────────────────────────
[[ -f "$PROJ/device.conf" ]] || die "no device.conf"
# shellcheck disable=SC1091
source "$PROJ/device.conf"
[[ -f "$PROJ/sources.lock" ]] && source "$PROJ/sources.lock"

# Refuse in seconds, not after an hour of compiling.
[[ "${MODULE_LAYOUT:-}" =~ ^0x[0-9a-fA-F]{8}$ ]] || die \
"device.conf MODULE_LAYOUT is empty or not an 8-digit CRC ('${MODULE_LAYOUT:-}').
 Obtain it from any module this device ships:
   modprobe --dump-modversions <vendor>.ko | awk '\$2==\"module_layout\"{print \$1}'"

KERNEL_WS="${KERNEL_WS:-$PROJ/.build/kernel}"
KMI_REF_TREE="${KMI_REF_TREE:-$PROJ/.build/kmi-ref}"

# ── Optional custom clang, e.g. Neutron clang 24 ────────────────────────────
# Kleaf's default is the CLANG_VERSION in the pinned tree (r536225 here). Set
# CLANG_DIR to a toolchain with the AOSP layout (bin/clang, bin/ld.lld, ...) to
# build with it instead. Kleaf's own --user_clang_toolchain plumbing does the
# symlinking, so nothing in the workspace is replaced.
if [[ -n "${CLANG_DIR:-}" ]]; then
  [[ "$CLANG_DIR" == /* ]] || CLANG_DIR="$PROJ/$CLANG_DIR"
  for _t in bin/clang bin/clang++ bin/llvm-ar bin/llvm-strip bin/llvm-objcopy bin/ld.lld; do
    [[ -x "$CLANG_DIR/$_t" ]] || die "CLANG_DIR=$CLANG_DIR has no executable $_t"
  done
  case "$CLANG_DIR" in
    *[[:space:]]*|*:*) die "CLANG_DIR contains a space or colon: '$CLANG_DIR' — move it." ;;
  esac
fi

# Bazel's output_user_root can outgrow the source filesystem. Point it at
# another disk with KLEAF_OUTPUT_ROOT (must be absolute).
if [[ -n "${KLEAF_OUTPUT_ROOT:-}" ]]; then
  [[ "$KLEAF_OUTPUT_ROOT" == /* ]] || die "KLEAF_OUTPUT_ROOT must be absolute: '$KLEAF_OUTPUT_ROOT'"
  case "$KLEAF_OUTPUT_ROOT" in
    *[[:space:]]*|*:*) die "KLEAF_OUTPUT_ROOT contains a space or colon: '$KLEAF_OUTPUT_ROOT'" ;;
  esac
fi

# A build path containing a space breaks the kernel Makefile, pkg-config, meson
# and Kbuild — each with a different message, none of which names the variable.
for v in PROJ KERNEL_WS KMI_REF_TREE; do
  case "${!v}" in
    *[[:space:]]*|*:*) die "$v contains a space or a colon: '${!v}' — move it." ;;
  esac
done

# ── Preflight ───────────────────────────────────────────────────────────────
say "preflight"

# Check for a marker FILE. `git -C <dir> log` silently walks UP to the parent
# repo when <dir> has no .git, which makes an empty checkout look successful.
[[ -f "$KERNEL_WS/common/Makefile" ]] || die \
  "no kernel source at $KERNEL_WS/common (expected common/Makefile).
   Run:  repo init -u $KERNEL_MANIFEST_URL -b $KERNEL_MANIFEST_BRANCH --depth=1 && repo sync -c"
[[ -x "$KERNEL_WS/tools/bazel" ]] || die "no $KERNEL_WS/tools/bazel — the manifest linkfiles are missing"

# Refuse to build off a drifted source. `repo sync` tracks the branch and will
# fast-forward `common` past the pin without leaving the tree dirty — on
# 2026-09-29 that silently moved us one commit and restructured
# fs/proc/task_mmu.c by 579 lines. A build whose source is not the source the
# lockfile names is not reproducible, and the KMI gate cannot see the difference.
if [[ -n "${KERNEL_COMMON_REF:-}" ]]; then
  _cur="$(git -C "$KERNEL_WS/common" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [[ "$_cur" != "$KERNEL_COMMON_REF" ]]; then
    die "common is at ${_cur:0:9} but sources.lock pins ${KERNEL_COMMON_REF:0:9}.
     Restore it:  git -C $KERNEL_WS/common checkout $KERNEL_COMMON_REF
     or update sources.lock deliberately — but do not build off an unrecorded tree."
  fi
fi

KSRC_VER="$(awk -F' = ' '/^VERSION/{v=$2} /^PATCHLEVEL/{p=$2} /^SUBLEVEL/{s=$2}
                         END{print v"."p"."s}' "$KERNEL_WS/common/Makefile")"
KSRC_REF="$(git -C "$KERNEL_WS/common" rev-parse --short HEAD 2>/dev/null || echo unknown)"
KMI_GEN="$(awk -F= '/^KMI_GENERATION/{print $2}' "$KERNEL_WS/common/build.config.constants")"
echo "   source        : $KSRC_VER @ $KSRC_REF  (KMI_GENERATION=$KMI_GEN)"
if [[ -n "${CLANG_DIR:-}" ]]; then
  echo "   clang         : $("$CLANG_DIR/bin/clang" --version | head -1)  ($CLANG_DIR)"
else
  echo "   clang         : kleaf default $(awk -F= '/^CLANG_VERSION/{print $2}' "$KERNEL_WS/common/build.config.constants")"
fi

# The release string this build must produce: <VERSION>-<release tag of the variant>
# (device.conf release_tag: 6.12.38-Ujang-X-Hinojoburi / 6.12.38-ZUjang-X-HinojoburiZ).
# Validated here because each piece lands in a C string literal, in `uname -r`, and
# in a sed expression in brand_source().
RELEASE_TAG="$(release_tag "$VARIANT")"
LOCALVERSION_STR="-${RELEASE_TAG}"
EXPECT_REL="${KSRC_VER}${LOCALVERSION_STR}"
for v in BRAND RELEASE_TAG KBUILD_BUILD_USER KBUILD_BUILD_HOST; do
  [[ "${!v:-}" =~ ^[A-Za-z0-9._-]+$ ]] || die "device.conf $v='${!v:-}' — use only [A-Za-z0-9._-]"
done
# __NEW_UTS_LEN is 64: a longer release fails deep in the kernel build instead of here.
(( ${#EXPECT_REL} <= 64 )) || die "release '$EXPECT_REL' is ${#EXPECT_REL} chars; uname allows 64"
if [[ "$STOCK" == 0 ]]; then
  echo "   release       : $EXPECT_REL  (${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST})"
fi
echo "   KMI target    : $MODULE_LAYOUT"

# The AOSP hermetic python3 that lands on PATH during a build lacks pyelftools;
# find one that can actually parse an ELF and use it for the gates.
SYSPY=""
for c in python3 /usr/bin/python3; do
  "$c" -c 'import elftools' >/dev/null 2>&1 && { SYSPY="$c"; break; }
done
[[ -n "$SYSPY" ]] || die "no python3 with pyelftools — the KMI gate cannot run (pip install pyelftools)"
echo "   gate python   : $SYSPY"

NKO="$(find "$KMI_REF_TREE" -name '*.ko' 2>/dev/null | wc -l)"
[[ "$NKO" -gt 0 ]] || die \
  "no modules under $KMI_REF_TREE — run tools/extract-device-material.sh first.
   A gate with an empty reference set cannot fail, which is worse than no gate."
echo "   KMI reference : $NKO modules"

# ── Source hygiene ──────────────────────────────────────────────────────────
# Every build starts from a pristine tree plus transient patches, so a dirty
# tree is always leftovers from a crashed run — reset it rather than wedging the
# next build. KEEP_DIRTY=1 opts into abort-and-inspect for local hacking.
prepare_source() {
  local dirty
  dirty="$(git -C "$KERNEL_WS/common" status --porcelain 2>/dev/null | head -5)"
  if [[ -n "$dirty" ]]; then
    if [[ "${KEEP_DIRTY:-0}" == "1" ]]; then
      die "common/ is dirty and KEEP_DIRTY=1:
$dirty"
    fi
    echo "   common/ was dirty — resetting to pristine (leftovers from a crashed run)"
    git -C "$KERNEL_WS/common" checkout -- . 2>/dev/null || true
    git -C "$KERNEL_WS/common" clean -fd >/dev/null 2>&1 || true
  fi
}
cleanup() {
  local rc=$?
  git -C "$KERNEL_WS/common" checkout -- . 2>/dev/null || true
  git -C "$KERNEL_WS/common" clean -fd >/dev/null 2>&1 || true
  exit $rc
}

# ── Branding ────────────────────────────────────────────────────────────────
# kleaf composes the release as  <version><localversion file><CONFIG_LOCALVERSION>.
# The localversion file (stamp.bzl _write_localversion, rsync'd into $OUT_DIR) holds
# "-android16-5" + "-g<sha>[-dirty]", and gki_defconfig's LOCALVERSION is "-4k" —
# hence 6.12.38-android16-5-g1ad7be92b3ed-dirty-RivalAbadi-ksunext-4k in v1.
# 🪤 Blanking STABLE_SCMVERSIONS (the v1-era tools/workspace-status-clean.sh) can
#    NOT reach the clean form: stamp.bzl prepends "-$android_release-$KMI_GENERATION"
#    itself, after the workspace status is read. It removes only the -g<sha>.
# The builder is no better: kernel_env.bzl hard-exports KBUILD_BUILD_USER=kleaf
# AFTER sourcing the env, so nothing outside the sandbox can set it.
# Both strings are produced by two scripts in common/scripts/, which the EXIT trap
# git-reverts — so brand them there, transiently, and assert that each edit landed.
# KMI-inert: MODVERSIONS makes same_magic() skip the version token at module load,
# and first-stage init matches module dirs on major.minor only.
brand_source() {
  local slv="$KERNEL_WS/common/scripts/setlocalversion"
  local mch="$KERNEL_WS/common/scripts/mkcompile_h"
  # release = KERNELVERSION + CONFIG_LOCALVERSION: ignore every localversion* file.
  sed -i 's|^echo "${KERNELVERSION}${file_localversion}${config_localversion}${LOCALVERSION}${scm_version}"$|file_localversion=""\t# [brand] build.sh: drop kleaf -android16-N-g<sha> localversion\n&|' "$slv"
  grep -q '^file_localversion=""	# \[brand\]' "$slv" \
    || die "brand_source: setlocalversion did not take the edit — its final echo changed upstream"
  # builder = device.conf, not kleaf@build-host.
  sed -i "/^LD=\\\$3\$/a KBUILD_BUILD_USER=\"$KBUILD_BUILD_USER\"\t# [brand] build.sh\nKBUILD_BUILD_HOST=\"$KBUILD_BUILD_HOST\"\t# [brand] build.sh" "$mch"
  grep -q "^KBUILD_BUILD_USER=\"$KBUILD_BUILD_USER\"" "$mch" && grep -q "^KBUILD_BUILD_HOST=\"$KBUILD_BUILD_HOST\"" "$mch" \
    || die "brand_source: mkcompile_h did not take the edit — its 'LD=\$3' line changed upstream"
  say "branded: release $EXPECT_REL, builder ${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST}"
}

OUT="$PROJ/out/$VARIANT"
mkdir -p "$OUT"

if [[ "$GATE_ONLY" == 0 ]]; then
  prepare_source
  trap cleanup EXIT

  # ── Source modifications (patches/series) — every non-stock variant ───────
  # Strict git-apply onto the pristine pin, BEFORE ksunext (no file overlaps with
  # the SusFS patch today; applying ours first keeps them byte-exact regardless).
  if [[ "$STOCK" == 0 ]]; then
    say "applying source modifications (patches/series)"
    KERNEL_SRC="$KERNEL_WS/common" PROJ="$PROJ" "$PROJ/apply-mods.sh" \
      || die "source modifications failed — see above"
  fi

  # ── ksunext: KernelSU-Next + SusFS into the now-pristine tree ─────────────
  # Runs AFTER prepare_source (which guarantees pristine) and BEFORE configure, so
  # the Kconfig the fragment selects actually exists. The EXIT trap git-reverts the
  # tree afterwards, so a ksunext build never leaks into the next vanilla one.
  if [[ "$VARIANT" == "ksunext" && "$STOCK" == 0 ]]; then
    say "integrating KernelSU-Next + SusFS"
    KERNEL_SRC="$KERNEL_WS/common" PROJ="$PROJ" LOCKFILE="$PROJ/sources.lock" \
      "$PROJ/apply-ksunext-susfs.sh" || die "ksunext integration failed — see above"
  fi

  # ── Configure ─────────────────────────────────────────────────────────────
  BAZEL_ARGS=()
  if [[ "$STOCK" == 1 ]]; then
    say "config: PURE ACK — no fragments, no branding (control build)"
  else
    # The fragment kleaf sees is COMPOSED, the way the RS4 merges its fragment list:
    #   vanilla_defconfig  (+ <variant>_defconfig)  + a generated brand block.
    # Every variant inherits vanilla's tweaks without a hand copy, and the brand has
    # one source of truth (device.conf) instead of a literal in each file.
    FRAGS=("$PROJ/config/vanilla_defconfig")
    [[ "$VARIANT" != "vanilla" ]] && FRAGS+=("$PROJ/config/${VARIANT}_defconfig")
    for f in "${FRAGS[@]}"; do [[ -f "$f" ]] || die "no $f (use --stock to build without fragments)"; done
    # Only the generated block may set LOCALVERSION — a stray literal in a fragment
    # would silently decide the release string instead of device.conf.
    if grep -n '^CONFIG_LOCALVERSION' "${FRAGS[@]}"; then
      die "a fragment sets CONFIG_LOCALVERSION (above) — remove it; build.sh owns the brand"
    fi
    # kleaf needs the fragment inside the workspace and exported by a BUILD file.
    COMPOSED="$KERNEL_WS/common/${VARIANT}_defconfig"
    {
      for f in "${FRAGS[@]}"; do echo "# ── ${f#$PROJ/} ──"; cat "$f"; echo; done
      echo "# ── generated by build.sh from device.conf ──"
      echo "CONFIG_LOCALVERSION=\"$LOCALVERSION_STR\""
      echo "# CONFIG_LOCALVERSION_AUTO is not set"
    } > "$COMPOSED"
    # Keep our scratch fragment out of git's view. (It is NOT the cause of the
    # "maybe-dirty" release string — I guessed that and was wrong; see the stamp
    # note below. This is just hygiene so `git status` stays readable.)
    EXC="$KERNEL_WS/common/.git/info/exclude"
    if [[ -f "$EXC" ]] && ! grep -qx "${VARIANT}_defconfig" "$EXC"; then
      echo "${VARIANT}_defconfig" >> "$EXC"
    fi
    cp "$COMPOSED" "$OUT/composed_defconfig"   # what was actually built, kept with the gate logs
    say "config: gki_defconfig + ${FRAGS[*]#$PROJ/} + brand ($LOCALVERSION_STR)"
    BAZEL_ARGS+=("--defconfig_fragment=//common:${VARIANT}_defconfig")
    brand_source
  fi
  [[ -n "$JOBS" ]] && BAZEL_ARGS+=("--jobs=$JOBS")
  [[ -n "${CLANG_DIR:-}" ]] && BAZEL_ARGS+=("--user_clang_toolchain=$CLANG_DIR")
# gendwarfksyms --stable must reach make through bazel action env so that
# vmlinux.symvers CRCs match clang-19-built reference modules (neutron clang 24
# otherwise yields 0xf52a27c0 for net_ns_type_operations instead of 0xe22fd8a9).
BAZEL_ARGS+=("--action_env=KBUILD_GENDWARFKSYMS_STABLE=1")
  # --lto is an EXPERIMENT KNOB, not a tuning one. gki_defconfig ships LTO_NONE
  # on android14-6.1+ because kCFI no longer needs whole-program LTO, and the
  # device's own extracted config confirms LTO_NONE. Anything else is a
  # deliberate departure from the shipped configuration — which on 5.10 was
  # known to move module_layout and break every vendor module. Whether that is
  # still true on 6.12 is a measurement, and this flag is how to take it.
  if [[ -n "$LTO" ]]; then
    BAZEL_ARGS+=("--lto=$LTO")
    say "⚠ LTO OVERRIDE: --lto=$LTO  (stock is LTO_NONE; expect the gate to judge it)"
    OUT="$OUT-lto-$LTO"; mkdir -p "$OUT"
  fi

  # ── Build ─────────────────────────────────────────────────────────────────
  # LTO is OFF by default in gki_defconfig on android14-6.1+ (kCFI does not need
  # it), and the device's own extracted config confirms LTO_NONE — so we do NOT
  # pass --lto. Matching the stock config is the point.
  #
  # --config=stamp embeds the real SCM version. Without it kleaf emits a literal
  # placeholder — build/kernel/kleaf/impl/stamp.bzl:63 is
  #     stable_scmversion_cmd = "echo '-maybe-dirty'"
  # so "6.12.38-android16-5-maybe-dirty-4k" never meant the tree was dirty; it
  # meant stamping was off and kleaf had not looked. Stock reads
  # "…-gb575a0b6e647-ab14355190-4k", so a real -g<sha> is the honest match.
  #
  # Stamping is still wanted for the timestamp: it pins /proc/version's build date
  # to the source commit (SOURCE_DATE_EPOCH), so a rebuild is byte-reproducible.
  # The "-g<sha>[-dirty]" it also produces never reaches a branded release —
  # brand_source() drops kleaf's whole localversion file (see there).
  BAZEL_ARGS+=("--config=stamp")
  BAZEL_STARTUP_ARGS=()
  if [[ -n "${KLEAF_OUTPUT_ROOT:-}" ]]; then
    BAZEL_STARTUP_ARGS+=("--output_user_root=$KLEAF_OUTPUT_ROOT")
    echo "   bazel out     : $KLEAF_OUTPUT_ROOT"
  fi
  say "build: //common:kernel_aarch64"
  ( cd "$KERNEL_WS" && ./tools/bazel "${BAZEL_STARTUP_ARGS[@]}" build "${BAZEL_ARGS[@]}" //common:kernel_aarch64 ) \
    2>&1 | tee "$OUT/build.log"

  # ksunext: read the KernelSU-Next version the KERNEL compiled in, from its own
  # Kbuild's output — not the number apply-ksunext-susfs.sh computed from the source
  # clone. v1 and v2 logged "33312" there while the kernel took the fallback
  # (KSU_VERSION 1, tag v0.0.1); nothing read the build until a tester's manager did.
  if [[ "$VARIANT" == "ksunext" && "$STOCK" == 0 ]]; then
    if grep -q "KernelSU-Next version fallback" "$OUT/build.log" \
       || ! grep -qE -- "-- KernelSU-Next version: ${WILDKSU_VER_EXPECT:-?}\b" "$OUT/build.log"; then
      die "the kernel's KernelSU-Next version is not ${WILDKSU_VER_EXPECT:-?}:
$(grep -E 'KernelSU-Next (version|tag)' "$OUT/build.log" | sort -u)
   (no line at all = bazel reused a cached kernel; rebuild before trusting this one)"
    fi
    echo "   ksu in kernel : $(grep -oE 'KernelSU-Next version: [0-9]+' "$OUT/build.log" | sort -u | tail -1), $(grep -oE 'KernelSU-Next tag: [^ ]+' "$OUT/build.log" | sort -u | tail -1)"
  fi
fi

# ── Locate the artifacts ────────────────────────────────────────────────────
BIN="$KERNEL_WS/bazel-bin/common/kernel_aarch64"
SYMVERS="$(find "$BIN" -name vmlinux.symvers -print -quit 2>/dev/null || true)"
[[ -n "$SYMVERS" ]] || die "no vmlinux.symvers under $BIN — did the build produce anything?"
SYMBOLLIST="$(find "$KERNEL_WS/bazel-bin/common" -name 'abi_symbollist' -print -quit 2>/dev/null || true)"

KREL="$(find "$BIN" -name 'kernel.release' -print -quit 2>/dev/null || true)"
[[ -n "$KREL" ]] && echo "   kernel.release: $(cat "$KREL")"

# ── The release string is part of the deliverable: assert it, don't eyeball it ──
# Also the cheapest guard against bazel-bin being SHARED across variants — without
# it, `--gate-only` writes this variant's gate logs about whichever kernel was built
# last (the same mix-up that nearly shipped root as vanilla in v1).
if [[ "$STOCK" == 0 ]]; then
  GOT_REL="$( [[ -n "$KREL" ]] && cat "$KREL" || echo '<no kernel.release>')"
  [[ "$GOT_REL" == "$EXPECT_REL" ]] || die "kernel.release is '$GOT_REL', expected '$EXPECT_REL'.
   Either bazel-bin holds a different variant (re-run ./build.sh $VARIANT), or the
   branding did not take — check brand_source() against common/scripts/setlocalversion."
  BANNER="$(LC_ALL=C grep -aom1 'Linux version [^ ]* ([^)]*)' "$BIN/Image" 2>/dev/null || true)"
  [[ "$BANNER" == "Linux version $EXPECT_REL (${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST})" ]] \
    || die "Image banner is '$BANNER', expected 'Linux version $EXPECT_REL (${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST})'"
  echo "   banner        : $BANNER"
fi

# ── Feature check: the gate proves the ABI, not the feature set ─────────────
# A kernel whose BORE or ntsync was silently dropped gates exactly as clean as one
# that has them (the RS4 nearly shipped such a "vanilla"). So: every line of the
# composed fragment must be in the built .config, and every patch in the series
# must have its switch on and its probe symbol in System.map.
if [[ "$STOCK" == 0 ]]; then
  DOTCFG="$BIN/kernel_aarch64_dot_config"; SMAP="$BIN/System.map"
  [[ -f "$DOTCFG" && -f "$SMAP" ]] || die "no .config / System.map under $BIN"
  MISS=""
  while IFS= read -r l; do
    case "$l" in
      CONFIG_*=*)               grep -qxF "$l" "$DOTCFG" || MISS+="  $l"$'\n' ;;
      "# CONFIG_"*" is not set") o="${l#\# }"; o="${o%% *}"
                                 grep -q "^$o=" "$DOTCFG" && MISS+="  $l  (but it is set)"$'\n' ;;
    esac
  done < "$OUT/composed_defconfig"
  while read -r p cfg sym; do
    [[ "$cfg" == "-" ]] || grep -qx "$cfg=y" "$DOTCFG" || MISS+="  $p: $cfg is not =y"$'\n'
    [[ "$sym" == "-" ]] || awk -v s="$sym" '$3==s{f=1} END{exit !f}' "$SMAP" \
      || MISS+="  $p: symbol $sym not in System.map"$'\n'
  done < <(awk '!/^[[:space:]]*(#|$)/' "$PROJ/patches/series")
  [[ -z "$MISS" ]] || die "the built kernel is missing configured features:
$MISS"
  echo "   features      : fragment fully applied; $(awk '!/^[[:space:]]*(#|$)/ && $3!="-"' "$PROJ/patches/series" | wc -l) patch probes in System.map ($(awk '!/^[[:space:]]*(#|$)/ && $3=="-"' "$PROJ/patches/series" | wc -l) verified by gate layer 2)"
fi

# ── Gate ────────────────────────────────────────────────────────────────────
# Layer 1 — do the CRCs agree. Layer 3 — will every import actually resolve, and
# is it permitted. Layer 1 alone calls a kernel with too narrow a symbol list
# CLEAN, so both run and both must pass.
# 🪤 `set -euo pipefail` aborts the script the moment layer 1 exits non-zero,
#    so a FAILING layer 1 meant layer 3 never ran and its log read "did not run".
#    A diagnostic that disappears exactly when the build is broken is the one
#    time you need it. Both layers now always run; the verdict is computed after.
set +e
say "KMI gate — layer 1: symbol CRCs vs $NKO stock modules"
KMI_KNOWN_BAD_MODULES="${KMI_VENDOR_KNOWN_BAD:-}" \
  "$SYSPY" "$PROJ/lib/kmi_check.py" "$SYMVERS" "$KMI_REF_TREE" | tee "$OUT/kmi-check.log"
L1=${PIPESTATUS[0]}

# Layer 2 — will any stock module be refused for EXPORTING a protected symbol.
# Layers 1 and 3 only judge imports; v1 and v2 shipped with no Wi-Fi because the
# phone's Google-signed rfkill.ko / libarc4.ko are unsigned to our kernel and were
# refused under MODULE_SIG_PROTECT. See lib/protect_check.py.
say "KMI gate — layer 2: protected exports (MODULE_SIG_PROTECT)"
DOTCFG2="$BIN/kernel_aarch64_dot_config"
if grep -q '^CONFIG_MODULE_SIG_PROTECT=y' "$DOTCFG2" 2>/dev/null; then
  PLIST="$(find "$KERNEL_WS/bazel-bin/common/kernel_aarch64_config" -name protected_module_names_list -print -quit 2>/dev/null || true)"
  "$SYSPY" "$PROJ/lib/protect_check.py" "$BIN/vmlinux" "$BIN/kernel_aarch64_Module.symvers" "${PLIST:-<none>}" "$KMI_REF_TREE" \
    | tee "$OUT/protect-check.log"
  L2=${PIPESTATUS[0]}
else
  echo "RESULT: CLEAN — MODULE_SIG_PROTECT is off; no export is protected" | tee "$OUT/protect-check.log"
  L2=0
fi

say "KMI gate — layer 3: import accounting"
if [[ -n "$SYMBOLLIST" ]]; then
  "$SYSPY" "$PROJ/lib/import_check.py" "$SYMVERS" "$KMI_REF_TREE" "$SYMBOLLIST" | tee "$OUT/import-check.log"
else
  echo "   (no abi_symbollist found — running without the permitted-import check)"
  "$SYSPY" "$PROJ/lib/import_check.py" "$SYMVERS" "$KMI_REF_TREE" | tee "$OUT/import-check.log"
fi
L3=${PIPESTATUS[0]}

# ── system_dlkm: Google's GKI modules, which the ROM loads too ───────────────
# Same three layers against the third module set. Signed with the stock build's key,
# so unsigned to us: v1/v2 refused 27 of them under MODULE_SIG_PROTECT. Declared
# known-bad modules (device.conf KMI_SYSTEM_KNOWN_BAD) are reported, not counted.
S1=0; S2=0; S3=0
rm -f "$OUT/kmi-check-system.log" "$OUT/protect-check-system.log" "$OUT/import-check-system.log"
if [[ -d "${KMI_REF_SYSTEM_TREE:-}" ]] && [[ -n "$(find "$KMI_REF_SYSTEM_TREE" -name '*.ko' -print -quit)" ]]; then
  say "system_dlkm — layers 1, 2, 3 vs $(find "$KMI_REF_SYSTEM_TREE" -name '*.ko' | wc -l) GKI modules  (known-bad: ${KMI_SYSTEM_KNOWN_BAD:-none})"
  KMI_EXPECT_VERMAGIC="$KMI_SYSTEM_EXPECT_VERMAGIC" KMI_VERMAGIC_EXCEPTIONS="" \
  KMI_KNOWN_BAD_MODULES="${KMI_SYSTEM_KNOWN_BAD:-}" \
    "$SYSPY" "$PROJ/lib/kmi_check.py" "$SYMVERS" "$KMI_REF_SYSTEM_TREE" | tee "$OUT/kmi-check-system.log"
  S1=${PIPESTATUS[0]}
  if grep -q '^CONFIG_MODULE_SIG_PROTECT=y' "$DOTCFG2" 2>/dev/null; then
    "$SYSPY" "$PROJ/lib/protect_check.py" "$BIN/vmlinux" "$BIN/kernel_aarch64_Module.symvers" "${PLIST:-<none>}" "$KMI_REF_SYSTEM_TREE" \
      | tee "$OUT/protect-check-system.log"
    S2=${PIPESTATUS[0]}
  else
    echo "RESULT: CLEAN — MODULE_SIG_PROTECT is off; no export is protected" | tee "$OUT/protect-check-system.log"
  fi
  KMI_UNRESOLVED_EXPECTED="" KMI_KNOWN_BAD_MODULES="${KMI_SYSTEM_KNOWN_BAD:-}" \
    "$SYSPY" "$PROJ/lib/import_check.py" "$SYMVERS" "$KMI_REF_SYSTEM_TREE" ${SYMBOLLIST:+"$SYMBOLLIST"} \
    | tee "$OUT/import-check-system.log"
  S3=${PIPESTATUS[0]}
else
  echo "   (no system_dlkm reference at '${KMI_REF_SYSTEM_TREE:-}' — its GKI modules are NOT gated)"
fi

set -e
echo
if [[ "$L1" == 0 && "$L2" == 0 && "$L3" == 0 && "$S1" == 0 && "$S2" == 0 && "$S3" == 0 ]]; then
  if [[ "$STOCK" == 0 ]]; then
    STAGED="$PROJ/.build/staged-$VARIANT"
    rm -rf "$STAGED"; mkdir -p "$STAGED"
    for f in Image Image.lz4 Image.gz; do
      [[ -f "$BIN/$f" ]] && cp -f "$BIN/$f" "$STAGED/$f"
    done
    [[ -n "$KREL" && -f "$KREL" ]] && cp -f "$KREL" "$STAGED/kernel.release"
  fi
  echo "GATE: PASS — layers 1, 2 and 3 clean, vendor and system_dlkm."
else
  echo "GATE: FAIL — vendor 1/2/3=$L1/$L2/$L3  system_dlkm 1/2/3=$S1/$S2/$S3  (1=broken 2=vacuous 3=wrong reference set)"
  exit 1
fi
