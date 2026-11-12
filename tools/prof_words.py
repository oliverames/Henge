#!/usr/bin/env python3
"""Sort HV_PROF_IOS=2 samples (Documents/hvprof-words.txt, "p COUNT 0 WORD" lines) into what the
translator emitted them for: the software TLB check, guest context in the HvCpu (x28), the access
itself, branches, and guest instructions copied as they were. Usage: prof_words.py hvprof-words.txt"""
import sys
from collections import Counter

def kind(w):
    rn, rd = (w >> 5) & 31, w & 31
    # ubfx T, va, #14, #14: the TLB slot index (put_tlb_slot)
    if w & 0xffc00000 == 0xd3400000 and (w >> 16) & 63 == 14 and (w >> 10) & 63 == 27:
        return "tlb: slot index"
    # lsr U, U, #14 (ubfm immr 14, imms 63): the tag check
    if w & 0xffc00000 == 0xd3400000 and (w >> 16) & 63 == 14 and (w >> 10) & 63 == 63:
        return "tlb: tag check"
    # add T, x28, T, lsl #5/#7: the slot's address
    if w & 0xff200000 == 0x8b000000 and rn == 28 and (w >> 22) & 3 == 0 and (w >> 10) & 63 in (5, 7):
        return "tlb: slot address"
    # ldr x, [T, #tlb field]: tag or addend (offsets HV_CPU_TLB 0x580 .. +4 tables * 32)
    if w & 0xffc00000 == 0xf9400000 and rn != 28:
        off = ((w >> 10) & 0xfff) * 8
        if 0x580 <= off < 0x600:
            return "tlb: tag/addend load"
    # sub U, addr, U (shifted register, no shift)
    if w & 0xffe0fc00 == 0xcb000000 and rd == (w >> 16) & 31:
        return "tlb: tag subtract (likely)"
    # load/store (register offset, lsl #0, option 011): the access through [addr, addend]
    if w & 0x3b200c00 == 0x38200800 and (w >> 13) & 7 == 3 and not (w >> 12) & 1:
        return "access [addr, addend]"
    # anything on x28: guest registers and state kept in the HvCpu, spills, tables
    if w & 0x3b000000 == 0x39000000 and rn == 28:  # ldr/str (unsigned imm)
        return "x28: context load/store"
    if w & 0x3a000000 == 0x28000000 and rn == 28:  # ldp/stp
        return "x28: context pair"
    if w & 0x7f000000 in (0x34000000, 0x35000000, 0xb4000000, 0xb5000000):
        return "cbz/cbnz"
    if w & 0xfc000000 in (0x14000000, 0x94000000) or w & 0xff000010 == 0x54000000:
        return "branch"
    if w & 0xfffffc1f in (0xd61f0000, 0xd63f0000, 0xd65f0000):
        return "branch (register)"
    if w & 0x0a000000 == 0x08000000:
        return "other load/store"
    return "other (copied guest code mostly)"

def main():
    total, by_kind, by_word = 0, Counter(), Counter()
    for line in open(sys.argv[1]):
        p = line.split()
        if len(p) != 4 or p[0] != "p":
            continue
        n, w = int(p[1]), int(p[3], 16)
        total += n
        by_kind[kind(w)] += n
        by_word[w] += n
    print(f"{total} translated-code samples")
    for k, n in by_kind.most_common():
        print(f"{100.0 * n / total:6.2f}%  {k}")
    print("\ntop words:")
    for w, n in by_word.most_common(40):
        print(f"{100.0 * n / total:6.2f}%  {w:08x}  {kind(w)}")

main()
