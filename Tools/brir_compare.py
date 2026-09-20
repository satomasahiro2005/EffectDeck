#!/usr/bin/env python3
"""4ch BRIR を 2 つ並べて数字で比べる。

片方は M0Rf30/easyeffects-presets の generate-synthetic-binaural-room.js が吐く .irs、
もう片方は Tools/brir_render.cpp が吐くもの。**耳で比べる前にここを見る。**

並びはどちらも LL / LR / RL / RR（docs/virtual-room-design.md §43）。

  python Tools/brir_compare.py 元.irs 自分.wav
"""
import cmath
import math
import struct
import sys

NAMES = ["LL", "LR", "RL", "RR"]


def read_wav(path):
    """float32 か int16 の RIFF を (チャンネルごとの list, レート) で返す。"""
    with open(path, "rb") as f:
        raw = f.read()
    if raw[0:4] != b"RIFF" or raw[8:12] != b"WAVE":
        sys.exit("!! %s は RIFF/WAVE ではない" % path)
    pos, fmt, data = 12, None, None
    while pos + 8 <= len(raw):
        cid = raw[pos:pos + 4]
        size = struct.unpack_from("<I", raw, pos + 4)[0]
        body = raw[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            fmt = struct.unpack_from("<HHIIHH", body, 0)
        elif cid == b"data":
            data = body
        pos += 8 + size + (size & 1)
    if fmt is None or data is None:
        sys.exit("!! %s に fmt か data が無い" % path)
    tag, channels, rate, _, _, bits = fmt
    if tag == 3 and bits == 32:
        count = len(data) // 4
        flat = struct.unpack_from("<%df" % count, data, 0)
    elif tag == 1 and bits == 16:
        count = len(data) // 2
        flat = [v / 32768.0 for v in struct.unpack_from("<%dh" % count, data, 0)]
    else:
        sys.exit("!! %s: 対応していない形式 tag=%d bits=%d" % (path, tag, bits))
    out = [list(flat[c::channels]) for c in range(channels)]
    return out, rate


def energy(x):
    return sum(v * v for v in x)


def peak(x):
    return max((abs(v) for v in x), default=0.0)


def db(x):
    return -999.0 if x <= 0 else 10 * math.log10(x)


def first_arrival(x, floor=0.05):
    """最大値の floor 倍を最初に超えた位置。ITD を測るのに使う。"""
    limit = peak(x) * floor
    for i, v in enumerate(x):
        if abs(v) >= limit:
            return i
    return 0


def band_energy(x, rate):
    """300 Hz / 3 kHz で 3 つに割ったエネルギー。1 次で割る（DSP 側と同じ割り方）。"""
    out = []
    low = high = 0.0
    a_low = 1.0 - math.exp(-2 * math.pi * 300.0 / rate)
    a_high = 1.0 - math.exp(-2 * math.pi * 3000.0 / rate)
    bands = [0.0, 0.0, 0.0]
    for v in x:
        low += a_low * (v - low)
        high += a_high * (v - high)
        bands[0] += low * low
        bands[1] += (high - low) ** 2
        bands[2] += (v - high) ** 2
    total = sum(bands) or 1.0
    for b in bands:
        out.append(10 * math.log10(b / total) if b > 0 else -999.0)
    return out


def decay_time(x, rate):
    """後ろから積んだエネルギー（Schroeder）が -60 dB へ落ちるまでの秒。"""
    tail = 0.0
    curve = []
    for v in reversed(x):
        tail += v * v
        curve.append(tail)
    curve.reverse()
    if curve[0] <= 0:
        return 0.0
    peak_db = 10 * math.log10(curve[0])
    for i, v in enumerate(curve):
        if v <= 0:
            continue
        if 10 * math.log10(v) - peak_db <= -60.0:
            return i / rate
    return len(x) / rate


def report(label, channels, rate):
    print("=== %s (%d ch @ %d Hz, %d frames) ===" % (label, len(channels), rate, len(channels[0])))
    total = sum(energy(c) for c in channels)
    for name, c in zip(NAMES, channels):
        e = energy(c)
        bands = band_energy(c, rate)
        print("  %s  peak %7.4f  energy %+7.2f dB  低/中/高 %+6.1f %+6.1f %+6.1f  "
              "立ち上がり %4d  RT %.3f s"
              % (name, peak(c), db(e), bands[0], bands[1], bands[2],
                 first_arrival(c), decay_time(c, rate)))
    print("  合計 energy %+7.2f dB   全体の peak %7.4f" % (db(total), max(peak(c) for c in channels)))
    itd = first_arrival(channels[1]) - first_arrival(channels[0])
    ild = db(energy(channels[0])) - db(energy(channels[1]))
    print("  ITD(LL→LR) %d サンプル (%.0f us)   ILD %+.2f dB"
          % (itd, itd / rate * 1e6, ild))
    # 左右の対称。LL と RR、LR と RL が揃っていないとモデルが壊れている。
    print("  対称 LL/RR %+.2f dB   LR/RL %+.2f dB"
          % (db(energy(channels[0])) - db(energy(channels[3])),
             db(energy(channels[1])) - db(energy(channels[2]))))
    return total


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    a, rate_a = read_wav(sys.argv[1])
    b, rate_b = read_wav(sys.argv[2])
    if len(a) != 4 or len(b) != 4:
        sys.exit("!! どちらも 4ch でないと比べられない（%d / %d）" % (len(a), len(b)))
    ea = report("元", a, rate_a)
    print()
    eb = report("自分", b, rate_b)
    print()
    print("差: 全体 %+.2f dB" % (db(eb) - db(ea)))
    for name, ca, cb in zip(NAMES, a, b):
        ba = band_energy(ca, rate_a)
        bb = band_energy(cb, rate_b)
        print("  %s  低 %+6.1f  中 %+6.1f  高 %+6.1f  (自分 - 元)"
              % (name, bb[0] - ba[0], bb[1] - ba[1], bb[2] - ba[2]))


if __name__ == "__main__":
    main()
