#!/usr/bin/env python3
"""Synthetic test disc for sim/cd_e2e: OUTDIR/disc.{cue,bin,trk} (the bin and trk made by tools/cue2pocket.py) and OUTDIR/expect.txt.

Track 1: MODE2/2352 form 1 data sectors, every one distinct; track 2: AUDIO with its 150-sector pregap (INDEX 00) in the file.
expect.txt (disc.trk), expect2.txt (disc2.trk: one data track), decimal BCD bytes: GetTN first and last track; GetTD minute and second of track 1, track 2 and the lead-out (track 0).
"""
import os, subprocess, sys

SECTOR = 2352
DATA_SECS, PREGAP_SECS, AUDIO_SECS = 100, 150, 50


def bcd(v):
    return (v // 10) << 4 | (v % 10)


def msf(lba):
    return bcd(lba // 4500), bcd(lba // 75 % 60), bcd(lba % 75)


def data_sector(n):
    """File sector n (disc LBA n + 150): sync, header, subheader (form 1), 2,048 data bytes, 280 bytes of 'EDC/ECC'."""
    m, s, f = msf(n + 150)
    b = bytearray([0x00] + [0xFF] * 10 + [0x00, m, s, f, 0x02, 0, 0, 0x08, 0, 0, 0, 0x08, 0])
    b += bytes((n * 37 + k * 5 + (k >> 8) * 11 + 1) & 0xFF for k in range(2048))
    b += bytes((n + k) & 0xFF for k in range(280))
    assert len(b) == SECTOR
    return bytes(b)


def audio_sector(n):
    return bytes((n * 13 + k * 3) & 0xFF for k in range(SECTOR))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "out"
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "raw.bin"), "wb") as fh:
        for n in range(DATA_SECS):
            fh.write(data_sector(n))
        for n in range(PREGAP_SECS + AUDIO_SECS):
            fh.write(audio_sector(DATA_SECS + n))
    f2 = DATA_SECS + PREGAP_SECS
    with open(os.path.join(out, "raw.cue"), "w") as fh:
        fh.write('FILE "raw.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n'
                 '  TRACK 02 AUDIO\n    INDEX 00 %02d:%02d:%02d\n    INDEX 01 %02d:%02d:%02d\n'
                 % (DATA_SECS // 4500, DATA_SECS // 75 % 60, DATA_SECS % 75, f2 // 4500, f2 // 75 % 60, f2 % 75))
    tool = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "cue2pocket.py")
    subprocess.run([sys.executable, tool, os.path.join(out, "raw.cue"), "-o", os.path.join(out, "disc")], check=True)
    # second table: the same image as one data track (the image is not swapped; the table alone changes the disc)
    with open(os.path.join(out, "raw2.cue"), "w") as fh:
        fh.write('FILE "raw.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n')
    subprocess.run([sys.executable, tool, os.path.join(out, "raw2.cue"), "-o", os.path.join(out, "disc2")], check=True)
    with open(os.path.join(out, "expect2.txt"), "w") as fh:
        fh.write("%d %d\n" % (0x01, 0x01))
        for lba in (150, 150, 150 + DATA_SECS + PREGAP_SECS + AUDIO_SECS):
            fh.write("%d %d\n" % msf(lba)[:2])
    with open(os.path.join(out, "expect.txt"), "w") as fh:
        fh.write("%d %d\n" % (0x01, 0x02))
        for lba in (150, 150 + f2, 150 + f2 + AUDIO_SECS):     # tracks 1 and 2, then the lead-out (GetTD 0)
            fh.write("%d %d\n" % msf(lba)[:2])


if __name__ == "__main__":
    main()
