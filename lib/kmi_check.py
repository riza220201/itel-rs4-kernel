#!/usr/bin/env python3
"""Cross-check a built kernel's symbol CRCs against the stock vendor modules.

Usage: kmi_check.py <vmlinux.symvers> <vendor_dlkm_dir_with_.ko>

Prints refs / mismatches / module_layout status and exits non-zero if any
vendor module would be rejected (CRC mismatch) — i.e. the kernel is NOT
KMI-clean for this device and must not ship.
"""
import sys, struct, glob, os
from elftools.elf.elffile import ELFFile

if len(sys.argv) != 3:
    sys.exit("usage: kmi_check.py <vmlinux.symvers> <vendor_ko_dir>")
symvers_path, ko_dir = sys.argv[1], sys.argv[2]

sv = {}
with open(symvers_path) as f:
    for ln in f:
        p = ln.split('\t')
        if len(p) >= 2:
            sv[p[1].strip()] = int(p[0], 16) & 0xffffffff

tot = match = mism = missing = ml_ok = ml_bad = 0
examples = []
kos = sorted(glob.glob(os.path.join(ko_dir, '*.ko')))
for ko in kos:
    sec = ELFFile(open(ko, 'rb')).get_section_by_name('__versions')
    if not sec:
        continue
    d = sec.data()
    for i in range(0, len(d), 64):               # modversion_info = 8B crc + 56B name
        c = d[i:i+64]
        if len(c) < 64:
            break
        crc = struct.unpack('<Q', c[:8])[0] & 0xffffffff
        nm = c[8:].split(b'\x00')[0].decode('latin1')
        if not nm:
            continue
        tot += 1
        if nm in sv:
            if sv[nm] == crc:
                match += 1
                if nm == 'module_layout':
                    ml_ok += 1
            else:
                mism += 1
                if nm == 'module_layout':
                    ml_bad += 1
                elif len(examples) < 15:
                    examples.append((nm, hex(crc), hex(sv[nm])))
        else:
            missing += 1                          # inter-vendor symbol, resolved at load

print(f"modules checked : {len(kos)}")
print(f"symbol refs     : {tot}")
print(f"  MATCH         : {match}")
print(f"  CRC-MISMATCH  : {mism}")
print(f"  not-in-vmlinux: {missing}  (inter-vendor, resolved at load — expected)")
print(f"module_layout   : ok={ml_ok} bad={ml_bad}")
if examples:
    print("sample mismatches (name, module-wants, our-vmlinux):")
    for e in examples:
        print("   ", e)

if len(kos) == 0 or ml_ok + ml_bad == 0:
    print(f"RESULT: checked {len(kos)} modules / {ml_ok+ml_bad} module_layout refs — "
          f"nothing to verify (wrong vendor_dlkm path?). NOT a pass.")
    sys.exit(2)
if mism == 0:
    print("RESULT: CLEAN — all vendor modules load natively (KMI-safe to ship)")
    sys.exit(0)
else:
    print(f"RESULT: {mism} CRC mismatches — KMI BROKEN, do NOT ship")
    sys.exit(1)
