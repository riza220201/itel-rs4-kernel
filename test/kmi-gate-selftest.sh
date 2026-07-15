#!/usr/bin/env bash
# KMI-gate self-test — proves the gate actually REJECTS a KMI-broken kernel (a
# positive-only gate that never fails is worthless). Exercises BOTH gate layers
# against a REAL build's symvers + the stock vendor_dlkm:
#   Layer 1 (build.sh):  module_layout string == device MODULE_LAYOUT
#   Layer 2 (kmi_check): full CRC cross-check vs the 198 vendor modules
#
# Cases: a good symvers must PASS; a symvers with a tampered module_layout, a
# tampered vendor-referenced symbol, or empty content must all be REJECTED.
#
# Needs a real symvers + vendor_dlkm (produced by `./build.sh <variant>`); it is
# a pre-release / regression check, not part of the build. Vendor .ko are the
# device's proprietary blobs (not shipped here), so this runs where they exist.
#   ./test/kmi-gate-selftest.sh [symvers] [vendor_ko_dir]
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Locate a real symvers + vendor_dlkm (args override; else autodetect).
SYMVERS="${1:-}"
VKDIR="${2:-}"
if [[ -z "$SYMVERS" ]]; then
  SYMVERS="$(ls -t "$PROJ"/.build/out-*/vmlinux.symvers 2>/dev/null | head -1)"
fi
[[ -z "$VKDIR" ]] && VKDIR="$PROJ/.build/vendor_dlkm"
# device MODULE_LAYOUT (layer-1 target)
DEVICE_CONF="$PROJ/device.conf"; MODULE_LAYOUT=""
# shellcheck source=/dev/null
[[ -f "$DEVICE_CONF" ]] && source "$DEVICE_CONF"

pass=0; fail=0
ok()  { echo "  ✓ $*"; pass=$((pass+1)); }
bad() { echo "  ✗ $*"; fail=$((fail+1)); }
skip(){ echo "  ⚠ SKIP: $*"; }

[[ -f "$SYMVERS" ]] || { skip "no vmlinux.symvers found (run ./build.sh <variant> first)"; exit 77; }
[[ -d "$VKDIR" && -n "$(ls "$VKDIR"/*.ko 2>/dev/null)" ]] || { skip "no vendor_dlkm/*.ko at $VKDIR"; exit 77; }
SYSPY=""; for p in /usr/bin/python3 /usr/local/bin/python3 python3; do "$p" -c 'import elftools' 2>/dev/null && { SYSPY="$p"; break; }; done
[[ -n "$SYSPY" ]] || { skip "no python3 with pyelftools"; exit 77; }

echo "KMI-gate self-test"
echo "  symvers      : $SYMVERS"
echo "  vendor_dlkm  : $VKDIR ($(ls "$VKDIR"/*.ko | wc -l) .ko)"
echo "  MODULE_LAYOUT: ${MODULE_LAYOUT:-<unset>}"
echo

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
GATE=( "$SYSPY" "$PROJ/lib/kmi_check.py" )

# helper: rewrite a symbol's CRC in a symvers copy
tamper() { awk -F'\t' -v s="$1" -v c="$2" 'BEGIN{OFS="\t"} $2==s{$1=c} {print}' "$SYMVERS" > "$3"; }
# layer-1 check (build.sh's module_layout string compare)
layer1() { local got; got="$(awk '$2=="module_layout"{print $1}' "$1")"; [[ "$got" == "$MODULE_LAYOUT" ]]; }

echo "[positive control] a real, unmodified symvers must PASS"
"${GATE[@]}" "$SYMVERS" "$VKDIR" >/dev/null 2>&1 \
  && ok "clean symvers → gate exit 0 (CLEAN)" \
  || bad "clean symvers was REJECTED (gate broken or stale artifacts)"
{ [[ -n "$MODULE_LAYOUT" ]] && layer1 "$SYMVERS"; } && ok "layer-1: module_layout matches device target" \
  || { [[ -n "$MODULE_LAYOUT" ]] && bad "layer-1 rejected a clean symvers" || skip "MODULE_LAYOUT unset — layer-1 skipped"; }

echo "[negative A] tampered module_layout CRC must be REJECTED"
tamper module_layout 0xdeadbeef "$W/ml.symvers"
"${GATE[@]}" "$W/ml.symvers" "$VKDIR" >/dev/null 2>&1 \
  && bad "layer-2 ACCEPTED a wrong module_layout (gate is a no-op!)" \
  || ok "layer-2: wrong module_layout → gate exit non-zero (rejected)"
if [[ -n "$MODULE_LAYOUT" ]]; then
  layer1 "$W/ml.symvers" && bad "layer-1 ACCEPTED a wrong module_layout" \
    || ok "layer-1: wrong module_layout → string check fails (rejected)"
fi

echo "[negative B] tampered vendor-referenced symbol CRC must be REJECTED"
# pick a real referenced symbol (present in symvers AND used by a vendor module)
SYM="$("$SYSPY" - "$SYMVERS" "$VKDIR" <<'PY'
import sys, glob, os
from elftools.elf.elffile import ELFFile
sv=set()
for ln in open(sys.argv[1]):
    p=ln.split('\t')
    if len(p)>=2: sv.add(p[1].strip())
for ko in sorted(glob.glob(os.path.join(sys.argv[2],'*.ko'))):
    sec=ELFFile(open(ko,'rb')).get_section_by_name('__versions')
    if not sec: continue
    d=sec.data()
    for i in range(0,len(d),64):
        c=d[i:i+64]
        if len(c)<64: break
        nm=c[8:].split(b'\x00')[0].decode('latin1')
        if nm and nm!='module_layout' and nm in sv:
            print(nm); raise SystemExit
PY
)"
if [[ -n "$SYM" ]]; then
  tamper "$SYM" 0xdeadbeef "$W/sym.symvers"
  "${GATE[@]}" "$W/sym.symvers" "$VKDIR" >/dev/null 2>&1 \
    && bad "full cross-check MISSED a tampered '$SYM' CRC" \
    || ok "full cross-check: tampered '$SYM' → gate exit non-zero (rejected)"
else
  skip "no referenced non-module_layout symbol found to tamper"
fi

echo "[negative C] empty symvers must be REJECTED (false-pass guard)"
: > "$W/empty.symvers"
"${GATE[@]}" "$W/empty.symvers" "$VKDIR" >/dev/null 2>&1 \
  && bad "empty symvers ACCEPTED (false pass!)" \
  || ok "empty symvers → gate exit non-zero (rejected)"

echo
echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
echo "✓ KMI gate correctly rejects broken kernels"
