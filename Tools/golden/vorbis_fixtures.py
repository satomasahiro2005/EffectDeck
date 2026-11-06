#!/usr/bin/env python3
"""SF3 の標本（モノの Ogg Vorbis）の見本を作る。Tests/Native/vorbis.c と Tests/Unit が読む。

  python3 Tools/golden/vorbis_fixtures.py [--ffmpeg ffmpeg] [--out Tests/Fixtures/SFZ/vorbis]

合成した波形（掃引・クリック・ノイズの切れ端。クリックで短いブロックが混ざる）を ffmpeg の libvorbis で符号化し、
同じ ffmpeg の復号器で読んだ 16 bit の PCM（<名前>.s16）を答えとして置く。復号は stb_vorbis（Sources/Shared/ETVorbis.c）が
同じ長さ・1 LSB 以内で出すことを Tests/Native/vorbis.c が確かめる。frames は ogg の最後のページの granule（上流の
readOggVorbisMetadata が frames にする値と同じ）で、ここで ogg から読み直す。

ffmpeg は見本を作り直すときだけ要る。出来た見本は置いてあり、試験は ffmpeg を使わない。
"""
import argparse
import json
import math
import pathlib
import random
import struct
import subprocess
import sys
import tempfile
import wave

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent

# 名前 -> (サンプルレート, フレーム数, 品質 -q:a, チャンネル数)。SF3 の標本はモノだけなので、2 チャンネルは「断る」試験用。
CASES = {
    "tone-44100": (44100, 12000, 5, 1),
    "rate-22050": (22050, 9000, 3, 1),
    "tiny-48000": (48000, 300, 5, 1),
    "long-44100": (44100, 70000, 0, 1),
    "stereo-44100": (44100, 4000, 5, 2),
}


def synth(rate, frames, seed):
    """掃引 + 数か所のクリック + 減衰するノイズの切れ端。範囲は ±0.8 に収める。"""
    rng = random.Random(seed)
    out = []
    phase = 0.0
    for n in range(frames):
        t = n / max(1, frames - 1)
        freq = 180.0 * (2.0 ** (t * 4.0))
        phase += 2.0 * math.pi * freq / rate
        v = 0.45 * math.sin(phase) + 0.15 * math.sin(phase * 2.01)
        out.append(v)
    for at in (frames // 5, frames // 2, (frames * 4) // 5):
        for k in range(min(40, frames - at)):
            out[at + k] += 0.5 * math.exp(-k / 6.0) * (1 if k % 2 == 0 else -1)
    for at in (frames // 3, (frames * 7) // 10):
        for k in range(min(900, frames - at)):
            out[at + k] += 0.3 * math.exp(-k / 250.0) * (rng.random() * 2 - 1)
    return [max(-0.8, min(0.8, v)) for v in out]


def write_wav(path, rate, samples, channels=1):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", int(round(v * 32767))) * channels for v in samples))


def last_granule(data):
    """最後のページ（EOS）の granule。"""
    at = 0
    while at + 27 <= len(data):
        assert data[at:at + 4] == b"OggS", "OggS が無い（%d）" % at
        nseg = data[at + 26]
        length = 27 + nseg + sum(data[at + 27:at + 27 + nseg])
        if data[at + 5] & 4:
            return struct.unpack_from("<q", data, at + 6)[0]
        at += length
    raise SystemExit("EOS のページが無い")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ffmpeg", default="ffmpeg")
    ap.add_argument("--out", default=str(ROOT / "Tests" / "Fixtures" / "SFZ" / "vorbis"))
    args = ap.parse_args()
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    manifest = {"note": "Tools/golden/vorbis_fixtures.py が作る。ref は ffmpeg の復号（s16le）。", "cases": []}
    with tempfile.TemporaryDirectory() as tmp:
        for seed, (name, (rate, frames, quality, channels)) in enumerate(CASES.items()):
            wav = pathlib.Path(tmp) / (name + ".wav")
            write_wav(wav, rate, synth(rate, frames, seed + 1), channels)
            ogg = out / (name + ".ogg")
            ref = out / (name + ".s16")
            subprocess.run([args.ffmpeg, "-v", "error", "-y", "-i", str(wav), "-ac", str(channels), "-c:a", "libvorbis",
                            "-q:a", str(quality), "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact",
                            str(ogg)], check=True)
            data = ogg.read_bytes()
            granule = last_granule(data)
            subprocess.run([args.ffmpeg, "-v", "error", "-y", "-i", str(ogg), "-f", "s16le", "-ac", str(channels), str(ref)],
                           check=True)
            decoded = ref.stat().st_size // (2 * channels)
            if decoded != granule:
                # ffmpeg が granule どおりに切っていない。見本としては granule の長さへ揃える。
                print("%s: ffmpeg の復号 %d フレーム、granule %d" % (name, decoded, granule), file=sys.stderr)
                body = ref.read_bytes()[: granule * 2 * channels]
                if len(body) != granule * 2 * channels:
                    raise SystemExit("%s: 答えが granule より短い" % name)
                ref.write_bytes(body)
            manifest["cases"].append({"name": name, "sampleRate": rate, "frames": granule, "channels": channels,
                                      "ogg": name + ".ogg", "ref": name + ".s16", "oggBytes": len(data)})
            print("%s: %d フレーム、ogg %d バイト" % (name, granule, len(data)))
    (out / "vorbis-golden.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
