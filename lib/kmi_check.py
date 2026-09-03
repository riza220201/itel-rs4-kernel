#!/usr/bin/env python3
"""Cross-check a built kernel's symbol CRCs against the stock vendor modules.

Usage: kmi_check.py <vmlinux.symvers> <vendor_dlkm_dir_with_.ko>

Prints refs / mismatches / module_layout status and exits non-zero if any
vendor module would be rejected (CRC mismatch) — i.e. the kernel is NOT
KMI-clean for this device and must not ship.

🔴 THE REFERENCE SET IS AN INPUT, AND AN INPUT CAN BE WRONG.
This gate answers "will my kernel load THESE modules". It cannot notice that
"these" stopped being the modules the device actually ships — and on 2026-09-03
that is exactly what was found: the reference directory still held a set that
had been replaced on 2026-09-02, so a healthy-looking `ok=198 bad=0` was
measured against modules nobody ships. Both sets passed, so nothing was
misjudged, but a gate wired to a stale input cannot fail.

So, optionally, assert the PROVENANCE of the reference set too. Set these in
device.conf (exported, so this subprocess sees them):

    export KMI_EXPECT_VERMAGIC="5.10.237-android12-9-gf280f42a626b"
    export KMI_VERMAGIC_EXCEPTIONS="mali_kbase_mt6789.ko"

Every reference module must then carry that vermagic prefix, except the named
files (modules you build yourself and therefore expect to differ). Anything else
is a wrong reference set and exits 3. Leave KMI_EXPECT_VERMAGIC unset to keep
the old CRC-only behaviour.
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


def vermagic_of(path):
    """Read vermagic out of the module's .modinfo section ('' if absent)."""
    sec = ELFFile(open(path, 'rb')).get_section_by_name('.modinfo')
    if not sec:
        return ''
    for field in sec.data().split(b'\x00'):
        if field.startswith(b'vermagic='):
            return field[len(b'vermagic='):].decode('latin1')
    return ''


tot = match = mism = missing = ml_ok = ml_bad = 0
examples = []
vermagics = {}
kos = sorted(glob.glob(os.path.join(ko_dir, '*.ko')))
for ko in kos:
    vermagics.setdefault(vermagic_of(ko).split(' ')[0], []).append(os.path.basename(ko))
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

print(f"reference set   : {ko_dir}")
print(f"modules checked : {len(kos)}")
print("vermagic        : " + ("  ".join(f"{len(v)}x {k or '(none)'}"
                                        for k, v in sorted(vermagics.items(),
                                                           key=lambda kv: -len(kv[1])))
                              or "(no modules)"))
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

# ── Provenance of the reference set (opt-in) ──────────────────────────────────
expect = os.environ.get('KMI_EXPECT_VERMAGIC', '').strip()
if expect:
    allowed = set(os.environ.get('KMI_VERMAGIC_EXCEPTIONS', '').replace(',', ' ').split())
    strays = sorted(name for vm, names in vermagics.items() for name in names
                    if not vm.startswith(expect) and name not in allowed)
    if strays:
        print(f"\nRESULT: {len(strays)} reference module(s) do NOT carry the expected "
              f"vermagic '{expect}' and are not listed as exceptions.")
        print("        This is a WRONG REFERENCE SET, not a bad kernel — the CRC result")
        print("        above is therefore about modules this device does not ship.")
        for name in strays[:10]:
            print(f"          {name}")
        if len(strays) > 10:
            print(f"          … and {len(strays)-10} more")
        sys.exit(3)
    present = {n for v in vermagics.values() for n in v}
    excused = sorted(allowed & present)
    print(f"provenance      : ok — {len(kos)-len(excused)} carry '{expect}'"
          + (f"; {len(excused)} declared exception(s): {', '.join(excused)}" if excused else ""))

if mism == 0:
    print("RESULT: CLEAN — all vendor modules load natively (KMI-safe to ship)")
    sys.exit(0)
else:
    print(f"RESULT: {mism} CRC mismatches — KMI BROKEN, do NOT ship")
    sys.exit(1)
