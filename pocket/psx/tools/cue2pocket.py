#!/usr/bin/env python3
"""cue2pocket: CUE/BIN (MODE1/2352, MODE2/2352, AUDIO; one or many files) -> one LBA-continuous .bin and the .trk track table
for the PSX core on the Analogue Pocket (CD image slot 1, track table slot 2).

  cue2pocket.py game.cue                    writes game.bin and game.trk next to the cue (or under -o PREFIX)
  cue2pocket.py game.cue --sbi game.sbi     also sets the libcrypt key from the SBI
  cue2pocket.py --selftest                  builds synthetic discs and checks the output against cd_top's lookups

Layout (file sector f = disc LBA f - 150 later; the core adds the 150-sector lead-in): the .bin is the input files back to back,
the first INDEX 01 at file sector 0, a PREGAP command expanded to zero sectors. The .trk format and its derivation from
rtl/cd_top.vhd are in docs/pocket/POCKET_TOP.md, "CD loader".
"""
import argparse, os, re, struct, sys, tempfile

SECTOR = 2352
PREGAP = 150            # cd_top.vhd PREGAPSIZE

# (key bit, first LBA); the second LBA of each pair is +5. cd_top.vhd:2612-2628, tested against lastReadSector + 2.
LIBCRYPT = [(15, 14105), (14, 14231), (13, 14485), (12, 14579), (11, 14649), (10, 14899), (9, 15056), (8, 15130),
            (7, 15242), (6, 15312), (5, 15378), (4, 15628), (3, 15919), (2, 16031), (1, 16101), (0, 16167)]


def bcd(v):
    if not 0 <= v <= 99:
        raise ValueError("BCD out of range: %d" % v)
    return (v // 10) << 4 | (v % 10)


def msf_frames(s):
    m, sec, f = (int(x) for x in s.split(":"))
    return (m * 60 + sec) * 75 + f


class Track:
    def __init__(self, num, mode):
        self.num, self.mode = num, mode
        self.idx0 = None
        self.idx1 = None
        self.pregap = 0
        self.file = None


def parse_cue(path):
    """-> list of (filename, size_in_sectors), list of Track. Each Track.file is an index into the file list."""
    base = os.path.dirname(os.path.abspath(path))
    files, tracks, cur = [], [], None
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            m = re.match(r'FILE\s+(?:"([^"]*)"|(\S+))\s+(\S+)', line, re.I)
            if m:
                name = m.group(1) if m.group(1) is not None else m.group(2)
                if m.group(3).upper() != "BINARY":
                    raise SystemExit("FILE type %s not supported (BINARY only)" % m.group(3))
                p = os.path.join(base, name.replace("\\", os.sep))
                if not os.path.isfile(p):
                    raise SystemExit("missing file: %s" % p)
                size = os.path.getsize(p)
                if size % SECTOR:
                    raise SystemExit("%s: size %d is not a multiple of 2352 (MODE1/2048 and other layouts are not supported)" % (p, size))
                files.append((p, size // SECTOR))
                continue
            m = re.match(r"TRACK\s+(\d+)\s+(\S+)", line, re.I)
            if m:
                mode = m.group(2).upper()
                if mode not in ("MODE1/2352", "MODE2/2352", "AUDIO"):
                    raise SystemExit("track %s: mode %s not supported (MODE1/2352, MODE2/2352, AUDIO)" % (m.group(1), mode))
                if not files:
                    raise SystemExit("TRACK before FILE")
                cur = Track(int(m.group(1)), mode)
                cur.file = len(files) - 1
                tracks.append(cur)
                continue
            m = re.match(r"INDEX\s+(\d+)\s+(\d+:\d+:\d+)", line, re.I)
            if m and cur:
                n = int(m.group(1))
                if n == 0:
                    cur.idx0 = msf_frames(m.group(2))
                elif n == 1:
                    cur.idx1 = msf_frames(m.group(2))
                continue
            m = re.match(r"PREGAP\s+(\d+:\d+:\d+)", line, re.I)
            if m and cur:
                cur.pregap = msf_frames(m.group(1))
    if not tracks:
        raise SystemExit("no tracks in the cue")
    for i, t in enumerate(tracks):
        if t.idx1 is None:
            raise SystemExit("track %d has no INDEX 01" % t.num)
        if t.num != i + 1:
            raise SystemExit("tracks must be numbered 1..N in order (track %d at position %d)" % (t.num, i + 1))
    if len(tracks) > 99:
        raise SystemExit("more than 99 tracks")
    return files, tracks


def layout(files, tracks):
    """Pieces of the output stream and each track's INDEX 01 sector s_n. A piece is ('z', n) zero sectors or
    ('f', file, first, count). The leading sectors before track 1's INDEX 01 are dropped (s_1 = 0)."""
    pieces = []
    pos = 0
    s = []
    for i, t in enumerate(tracks):
        first_in_file = not any(u.file == t.file for u in tracks[:i])
        start = 0 if first_in_file else (t.idx0 if t.idx0 is not None else t.idx1)
        end = files[t.file][1]
        for u in tracks[i + 1:]:
            if u.file == t.file:
                end = u.idx0 if u.idx0 is not None else u.idx1
                break
        if start > t.idx1 or end < t.idx1 or end > files[t.file][1]:
            raise SystemExit("track %d: indexes outside the file" % t.num)
        if t.pregap:
            pieces.append(("z", t.pregap)); pos += t.pregap
        pieces.append(("f", t.file, start, end - start))
        s.append(pos + (t.idx1 - start))
        pos += end - start
    return pieces, s, pos


def skip_sectors(pieces, n):
    out = []
    for p in pieces:
        cnt = p[1] if p[0] == "z" else p[3]
        if n >= cnt:
            n -= cnt
            continue
        if p[0] == "z":
            out.append(("z", cnt - n))
        else:
            out.append(("f", p[1], p[2] + n, cnt - n))
        n = 0
    return out


def write_bin(pieces, files, out):
    zero = bytes(SECTOR * 64)
    handles = {}
    with open(out, "wb") as o:
        for p in pieces:
            if p[0] == "z":
                left = p[1]
                while left:
                    k = min(left, 64)
                    o.write(zero[:k * SECTOR]); left -= k
            else:
                fh = handles.get(p[1]) or open(files[p[1]][0], "rb")
                handles[p[1]] = fh
                fh.seek(p[2] * SECTOR)
                left = p[3] * SECTOR
                while left:
                    b = fh.read(min(left, 1 << 22))
                    if not b:
                        raise SystemExit("short read")
                    o.write(b); left -= len(b)
    for fh in handles.values():
        fh.close()


def read_sectors(pieces, files, first, count):
    """The bytes of output sectors first..first+count-1 (for the region scan; sectors beyond the end are not returned)."""
    out = bytearray()
    pos = 0
    for p in pieces:
        cnt = p[1] if p[0] == "z" else p[3]
        lo, hi = max(first, pos), min(first + count, pos + cnt)
        if lo < hi:
            if p[0] == "z":
                out += bytes((hi - lo) * SECTOR)
            else:
                with open(files[p[1]][0], "rb") as fh:
                    fh.seek((p[2] + lo - pos) * SECTOR)
                    out += fh.read((hi - lo) * SECTOR)
        pos += cnt
    return bytes(out)


def detect_region(data):
    """0 unknown, 1 Japan, 2 America, 3 Europe, from the licence text of the system area."""
    if b"Sony Computer Entertainment Inc." not in data:
        return 0
    if re.search(rb"for\s+Japan\s+area", data):
        return 1
    if re.search(rb"of\s+America\s+area", data):
        return 2
    if re.search(rb"for\s+Europe\s+area", data):
        return 3
    return 0


def sbi_key(path):
    """Libcrypt key from an SBI file: bit set when the sector (MSF as an absolute LBA) of a pair is listed."""
    d = open(path, "rb").read()
    if d[:4] != b"SBI\0":
        raise SystemExit("%s: not an SBI file" % path)
    lbas = set()
    i = 4
    while i + 4 <= len(d):
        m, sec, f, typ = d[i], d[i + 1], d[i + 2], d[i + 3]
        for v in (m, sec, f):
            if (v & 0xF) > 9 or (v >> 4) > 9:
                raise SystemExit("%s: bad BCD at byte %d" % (path, i))
        n = ((m >> 4) * 10 + (m & 15)) * 60 + (sec >> 4) * 10 + (sec & 15)
        lbas.add(n * 75 + (f >> 4) * 10 + (f & 15))
        i += 4 + {1: 10, 2: 3, 3: 3}.get(typ, 0)
    key = 0
    for bit, first in LIBCRYPT:
        if first in lbas or first + 5 in lbas:
            key |= 1 << bit
    return key


def build_trk(tracks, s, total, key, region, reset):
    """Words of the .trk, little-endian 32-bit, as cd_top.vhd:3139-3180 reads them: word 0..3 header, then 4 words per track
    at word index 4*track number."""
    n = len(tracks)
    lead = total + PREGAP
    w = [0] * (4 * (n + 1))
    w[0] = n | bcd(n) << 8
    w[1] = lead
    w[2] = bcd((lead // 75) % 60) | bcd(lead // 4500) << 8
    w[3] = key | region << 16 | (1 if reset else 0) << 18
    for i, t in enumerate(tracks):
        start = s[i]
        end = (s[i + 1] - 1) if i + 1 < n else lead - 1
        lba1 = s[i] + PREGAP
        w[4 * (i + 1) + 0] = start
        w[4 * (i + 1) + 1] = end
        w[4 * (i + 1) + 2] = bcd((lba1 // 75) % 60) | bcd(lba1 // 4500) << 8 | (1 if t.mode == "AUDIO" else 0) << 16
        w[4 * (i + 1) + 3] = 0
    if len(w) * 4 > 2048:
        raise SystemExit("track table over 2,048 bytes")
    return struct.pack("<%dI" % len(w), *w)


def convert(cue, out_prefix, sbi=None, region="auto", reset=True, copy=True, quiet=False):
    files, tracks = parse_cue(cue)
    pieces, s, total = layout(files, tracks)
    lead = s[0]
    s = [x - lead for x in s]
    pieces = skip_sectors(pieces, lead)
    total -= lead
    if region == "auto":
        reg = 0
        for first in (0, 150):   # the licence text is in the first data track's system area
            reg = detect_region(read_sectors(pieces, files, first, 16))
            if reg:
                break
    else:
        reg = {"none": 0, "jp": 1, "us": 2, "eu": 3}[region]
    key = sbi_key(sbi) if sbi else 0
    trk = build_trk(tracks, s, total, key, reg, reset)
    as_is = len(pieces) == 1 and pieces[0][0] == "f" and pieces[0][2] == 0
    if copy:
        write_bin(pieces, files, out_prefix + ".bin")
    with open(out_prefix + ".trk", "wb") as o:
        o.write(trk)
    if not quiet:
        print("%d tracks, %d sectors (%d bytes), region %s, libcrypt key %04X" %
              (len(tracks), total, total * SECTOR, ["unknown", "JP", "US", "EU"][reg], key))
        for i, t in enumerate(tracks):
            print("  track %02d %-10s INDEX 01 at sector %d" % (t.num, t.mode, s[i]))
        if as_is:
            print("note: the input is already LBA-continuous; %s can be used as it is" % files[pieces[0][1]][0])
    return trk, s, total, reg, key


# ------------------------------------------------------------------------------------------------ self-test
def selftest():
    def sector(tag, i):
        b = bytearray(SECTOR)
        b[0:8] = struct.pack("<II", tag, i)
        for k in range(8, SECTOR):
            b[k] = (tag * 31 + i * 7 + k) & 0xFF
        return bytes(b)

    def mk(path, tag, n, first=0, patch=None):
        with open(path, "wb") as fh:
            for i in range(n):
                sec = sector(tag, first + i)
                if patch and i in patch:
                    sec = patch[i](sec)
                fh.write(sec)

    def put_license(sec):
        b = bytearray(sec)
        txt = b"Sony Computer Entertainment Inc. for Europe area"
        b[24:24 + len(txt)] = txt
        return bytes(b)

    def decode(trk):
        w = struct.unpack("<%dI" % (len(trk) // 4), trk)
        return w

    def lookup(w, lba):
        """cd_top's track search (3100-3130): first track whose [start, end] holds lba."""
        for n in range(1, 100):
            if 4 * n + 3 >= len(w):
                return None
            if (w[4 * n] & 0x7FFFF) <= lba <= (w[4 * n + 1] & 0x7FFFF):
                return n
        return None

    fails = 0
    with tempfile.TemporaryDirectory() as d:
        # disc A: three files: data (MODE2), audio with INDEX 00 (150 pregap in the file), audio without pregap, PREGAP cmd
        mk(os.path.join(d, "t1.bin"), 1, 400, patch={4: put_license})
        mk(os.path.join(d, "t2.bin"), 2, 150 + 300)
        mk(os.path.join(d, "t3.bin"), 3, 200)
        with open(os.path.join(d, "a.cue"), "w") as fh:
            fh.write('FILE "t1.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n'
                     'FILE "t2.bin" BINARY\n  TRACK 02 AUDIO\n    INDEX 00 00:00:00\n    INDEX 01 00:02:00\n'
                     'FILE "t3.bin" BINARY\n  TRACK 03 AUDIO\n    PREGAP 00:02:00\n    INDEX 01 00:00:00\n')
        sbi = os.path.join(d, "a.sbi")
        with open(sbi, "wb") as fh:   # 14110 is the second LBA of bit 15, 16167 the first of bit 0
            def ent(lba):
                m, r = divmod(lba, 4500)
                sec, f = divmod(r, 75)
                return bytes([bcd(m), bcd(sec), bcd(f), 1]) + bytes(10)
            fh.write(b"SBI\0" + ent(14110) + ent(16167) + ent(999))
        trk, s, total, reg, key = convert(os.path.join(d, "a.cue"), os.path.join(d, "a"), sbi=sbi, quiet=True)
        out = open(os.path.join(d, "a.bin"), "rb").read()
        exp_total = 400 + 450 + 150 + 200
        checks = [
            (len(out) == exp_total * SECTOR, "bin size %d sectors, want %d" % (len(out) // SECTOR, exp_total)),
            (s == [0, 550, 1000], "INDEX 01 sectors %s" % s),
            (reg == 3, "region %d, want 3 (EU)" % reg),
            (key == 0x8001, "libcrypt key %04X, want 8001" % key),
            (len(trk) == 4 * 4 * 4, "trk size %d" % len(trk)),
        ]
        w = decode(trk)
        checks += [
            (w[0] == 3 | 3 << 8, "word 0 %08X" % w[0]),
            (w[3] == 0x8001 | 3 << 16 | 1 << 18, "word 3 %08X" % w[3]),
            (w[4] == 0 and w[5] == 549, "track 1 range %d..%d" % (w[4], w[5])),
            (w[8] == 550 and w[9] == 999, "track 2 range %d..%d" % (w[8], w[9])),
            (w[12] == 1000 and w[13] == total + PREGAP - 1, "track 3 range %d..%d" % (w[12], w[13])),
        ]
        # every LBA belongs to exactly the track whose file data it reads; the file sector is lba - 150
        total_lba = total + PREGAP
        for lba in (0, 149, 150, 200, 549, 550, 699, 700, 999, 1000, 1049, 1199, total_lba - 1):
            n = lookup(w, lba)
            want = 1 if lba < s[1] else 2 if lba < s[2] else 3
            checks.append((n == want, "lba %d in track %s, want %d" % (lba, n, want)))
            if lba >= PREGAP and lba - PREGAP < total:
                fs = lba - PREGAP
                got = out[fs * SECTOR:(fs + 1) * SECTOR]
                if fs < 400:
                    exp = sector(1, fs) if fs != 4 else put_license(sector(1, 4))
                elif fs < 850:
                    exp = sector(2, fs - 400)
                elif fs < 1000:
                    exp = bytes(SECTOR)           # the PREGAP command
                else:
                    exp = sector(3, fs - 1000)
                checks.append((got == exp, "file sector %d content" % fs))
        checks.append((lookup(w, total_lba) is None, "lead-out lba found a track"))
        # track 2 INDEX 01 at lba 550 + 150 = 700 -> 00:09
        checks.append(((w[10] & 0xFFFF) == 0x0009, "track 2 time %04X" % (w[10] & 0xFFFF)))
        checks.append((w[10] >> 16 & 1 == 1 and w[6] >> 16 & 1 == 0, "isAudio bits"))
        lead = total_lba
        checks.append((w[2] == (bcd((lead // 75) % 60) | bcd(lead // 4500) << 8), "total time %04X" % w[2]))

        # disc B: one bin, MODE1, data + audio with INDEX 00; the bin is used as it is
        mk(os.path.join(d, "b.bin"), 5, 1000)
        with open(os.path.join(d, "b.cue"), "w") as fh:
            fh.write('FILE "b.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n'
                     '  TRACK 02 AUDIO\n    INDEX 00 00:09:00\n    INDEX 01 00:11:00\n')
        trk, s, total, reg, key = convert(os.path.join(d, "b.cue"), os.path.join(d, "bo"), quiet=True)
        w = decode(trk)
        checks += [
            (s == [0, 825], "disc B sectors %s" % s),
            (open(os.path.join(d, "bo.bin"), "rb").read() == b"".join(sector(5, i) for i in range(1000)), "disc B content"),
            (w[5] == 824 and w[8] == 825 and w[9] == 1149, "disc B ranges %d %d %d" % (w[5], w[8], w[9])),
            (reg == 0 and key == 0, "disc B region %d key %d" % (reg, key)),
        ]
        # disc C: INDEX 01 of track 1 at 00:02:00 (pregap in the file): the leading 150 sectors are dropped
        mk(os.path.join(d, "c.bin"), 6, 300)
        with open(os.path.join(d, "c.cue"), "w") as fh:
            fh.write('FILE "c.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 00 00:00:00\n    INDEX 01 00:02:00\n')
        trk, s, total, reg, key = convert(os.path.join(d, "c.cue"), os.path.join(d, "co"), quiet=True)
        out = open(os.path.join(d, "co.bin"), "rb").read()
        checks += [(total == 150 and out == b"".join(sector(6, i) for i in range(150, 300)), "disc C leading pregap dropped")]
    for ok, msg in checks:
        if not ok:
            print("FAIL:", msg)
            fails += 1
    print("PASS" if not fails else "FAIL (%d)" % fails)
    return fails


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cue", nargs="?", help="the CUE sheet")
    ap.add_argument("-o", "--out", help="output prefix (default: the cue path without .cue); writes PREFIX.bin and PREFIX.trk")
    ap.add_argument("--sbi", help="SBI file: sets the libcrypt key")
    ap.add_argument("--region", choices=["auto", "jp", "us", "eu", "none"], default="auto",
                    help="region in the track table (auto: read from the disc's licence text)")
    ap.add_argument("--no-reset", action="store_true", help="do not ask the core to reset when the table is loaded")
    ap.add_argument("--trk-only", action="store_true", help="write only the .trk (the .bin is already LBA-continuous)")
    ap.add_argument("--selftest", action="store_true", help="run the self-test on synthetic images and exit")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(1 if selftest() else 0)
    if not a.cue:
        ap.error("a CUE file is required (or --selftest)")
    prefix = a.out or os.path.splitext(a.cue)[0]
    convert(a.cue, prefix, sbi=a.sbi, region=a.region, reset=not a.no_reset, copy=not a.trk_only)


if __name__ == "__main__":
    main()
