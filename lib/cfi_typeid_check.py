#!/usr/bin/env python3
"""Check a kernel built with a different compiler still speaks the vendor modules' CFI.

Usage: cfi_typeid_check.py <llvm-objdump> <reference-vmlinux> <new-vmlinux> <vendor_ko_dir>

5.10's CFI is clang's cross-DSO CFI: an indirect call from the kernel into a
vendor module passes a 64-bit type id (low 64 bits of MD5 of the mangled
function type, e.g. "_ZTSFiP4fileE") to that module's __cfi_check, and the
other way round. The vendor modules were compiled once, by clang-12 (r416183b).
If a new compiler derived type ids differently, every such call would trap
(CFI_PERMISSIVE is off -> panic) while the KMI gate stays CLEAN: the gate
compares symbol CRCs, not code.

Each __cfi_check is a switch on x0 lowered to a binary search: every id is
built with mov/movk and compared with `cmp x0, xN`. 🔴 Only the compares
followed by b.eq/b.ne are type ids. The b.gt/b.le ones are the search tree's
range pivots, which each LLVM version picks differently; counting them made
clang-24 look 18% incompatible on 2026-10-28 when it was not.

Pass = every id the reference kernel (one that booted) shares with the vendor
modules is also accepted by the new kernel. Exits 1 otherwise.
"""
import glob, os, re, subprocess, sys

if len(sys.argv) != 5:
    sys.exit("usage: cfi_typeid_check.py <llvm-objdump> <reference-vmlinux> <new-vmlinux> <vendor_ko_dir>")
objdump, ref, new, ko_dir = sys.argv[1:]

MOV = re.compile(r'\tmov\t(x\d+), #(-?0x[0-9a-f]+|-?\d+)')
MOVK = re.compile(r'\tmovk\t(x\d+), #(0x[0-9a-f]+|\d+)(?:, lsl #(\d+))?')
CMP = re.compile(r'\tcmp\tx0, (x\d+)$')
BR = re.compile(r'\tb\.(eq|ne)\t')


def type_ids(elfs):
    """Equality-tested constants in each ELF's __cfi_check (union)."""
    ids = set()
    for elf in elfs:
        out = subprocess.run([objdump, '-d', '--no-show-raw-insn',
                              '--disassemble-symbols=__cfi_check', elf],
                             capture_output=True, text=True, check=True).stdout
        reg, pend = {}, None
        for ln in out.splitlines():
            ln = ln.split('//')[0].rstrip()
            if pend is not None:
                if BR.search(ln):
                    ids.add(pend)
                pend = None
            if m := MOV.search(ln):
                reg[m[1]] = int(m[2], 0) & (2**64 - 1)
            elif m := MOVK.search(ln):
                sh = int(m[3] or 0)
                reg[m[1]] = (reg.get(m[1], 0) & ~(0xffff << sh) & (2**64 - 1)) | (int(m[2], 0) << sh)
            elif m := CMP.search(ln):
                pend = reg.get(m[1])
    return ids


kos = sorted(glob.glob(os.path.join(ko_dir, '*.ko')))
R, N, V = type_ids([ref]), type_ids([new]), type_ids(kos)
if not R or not N or not V:
    print(f"RESULT: no type ids found (ref {len(R)}, new {len(N)}, vendor {len(V)}) — "
          f"no __cfi_check? NOT a pass.")
    sys.exit(2)
need = V & R
lost = need - N
print(f"reference kernel : {len(R)} type ids  ({ref})")
print(f"new kernel       : {len(N)} type ids  ({new})")
print(f"  shared         : {len(R & N)}   only-reference {len(R - N)}   only-new {len(N - R)}")
print(f"vendor modules   : {len(V)} type ids in {len(kos)} modules")
print(f"  shared w/ ref  : {len(need)}   w/ new {len(V & N)}")
if lost:
    print(f"RESULT: {len(lost)} vendor-shared type id(s) the new kernel does not accept, e.g. "
          + ", ".join(f"{i:016x}" for i in sorted(lost)[:5]) + " — CFI cross-DSO BROKEN")
    sys.exit(1)
print(f"RESULT: CLEAN — all {len(need)} vendor-shared type ids hash the same")
