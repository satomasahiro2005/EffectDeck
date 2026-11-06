// sample_page_golden.mjs
// 流し込みの標本のページ（4096 フレーム）の見本を、上流の js/sfz/sample-stream.js そのものに作らせる。
// Swift の DSP/SFZStream/SFZPageDecode.swift（WAV / AIFF の頭の読みと PCM の float 化、SF2 の 16 bit + sm24）が、
// この見本と 1 ビットまで同じ float を作ることを SFZPageDecodeTests が見る。
//
//   root=$(bash Tools/golden/extract_pin.sh)
//   EFFETUNE_ROOT="$root" node Tools/golden/sample_page_golden.mjs [出力先]
//
// 入力は小さなファイル（WAV・AIFF・AIFC・SF2 の PCM の並び）を、ここで決まった式で作る。
// 上流の SfzSampleStream.open（頭の読み）→ readPages（ページ）の答えを、ファイルのバイトごと残す。
// 頭が通らないものは、上流の error.code を残す（Swift は同じ区別で断る）。
//
// 出力: Tests/Fixtures/SFZ/sample-page-golden.json

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.join(here, '..', '..');
const upstream = process.env.EFFETUNE_ROOT;
if (!upstream) {
    console.error('sample_page_golden.mjs: EFFETUNE_ROOT が無い（bash Tools/golden/extract_pin.sh の出力を渡す）');
    process.exit(2);
}
const outFile = path.resolve(process.argv[2] ?? path.join(repo, 'Tests', 'Fixtures', 'SFZ', 'sample-page-golden.json'));
const { SfzSampleStream, SFZ_SAMPLE_PAGE_FRAMES } = await import(pathToFileURL(path.resolve(upstream, 'js/sfz/sample-stream.js')).href);

// ---- ファイルの作り手 ----
const ascii = text => Uint8Array.from([...text].map(char => char.charCodeAt(0)));
const concat = parts => {
    const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
    let at = 0;
    for (const part of parts) { out.set(part, at); at += part.length; }
    return out;
};
const u16 = (value, le) => le ? Uint8Array.of(value & 255, value >> 8 & 255) : Uint8Array.of(value >> 8 & 255, value & 255);
const u32 = (value, le) => le ? Uint8Array.of(value & 255, value >> 8 & 255, value >> 16 & 255, value >>> 24)
    : Uint8Array.of(value >>> 24, value >> 16 & 255, value >> 8 & 255, value & 255);
const chunk = (tag, body, le) => concat([ascii(tag), u32(body.length, le), body, body.length & 1 ? Uint8Array.of(0) : new Uint8Array(0)]);

// 決まった式の整数。先頭の 4 つは両端と 0・-1（符号と丸めの端を必ず通す）。
function integer(frame, channel, bits, unsigned) {
    const half = 2 ** (bits - 1);
    const edge = [-half, half - 1, 0, -1][frame];
    const value = frame < 4 && channel === 0 ? edge : ((frame * 2654435761 + channel * 40503 + 12345) >>> 0) % (2 * half) - half;
    return unsigned ? value + half : value;
}

function samples(frames, channels, bits, { float = false, le = true, unsigned = false } = {}) {
    // 12 bit のような、語長が合わないもの（頭の検査で断られる）。中身は 0。
    if (!(float ? [32, 64] : [8, 16, 24, 32, 64]).includes(bits)) return new Uint8Array(frames * channels * Math.ceil(bits / 8));
    const width = bits / 8;
    const out = new Uint8Array(frames * channels * width);
    const view = new DataView(out.buffer);
    for (let frame = 0; frame < frames; frame++) {
        for (let channel = 0; channel < channels; channel++) {
            const at = (frame * channels + channel) * width;
            if (float) {
                // 0.1 のような 2 進で割り切れない値、1 に近い値、非正規数に近い値を混ぜる。
                const special = [0.1, -1, 1 - 2 ** -24, 1e-40, 3.4e38, -0, 2 ** -149, 0.3333333333333333][(frame + channel) % 8];
                const value = frame < 8 ? special : (integer(frame, channel, 24, false) / 8388608) * 1.0000001;
                if (bits === 32) view.setFloat32(at, value, le); else view.setFloat64(at, value, le);
            } else if (bits === 8) {
                out[at] = integer(frame, channel, 8, unsigned) & 255;
            } else if (bits === 16) {
                view.setInt16(at, integer(frame, channel, 16, false), le);
            } else if (bits === 24) {
                const value = integer(frame, channel, 24, false) & 0xffffff;
                const bytes = le ? [value & 255, value >> 8 & 255, value >> 16 & 255] : [value >> 16 & 255, value >> 8 & 255, value & 255];
                out.set(bytes, at);
            } else {
                view.setInt32(at, integer(frame, channel, 32, false), le);
            }
        }
    }
    return out;
}

function wav({ frames, channels, rate = 44100, bits, code = 1, extensible = false, extra = [], dataTrim = 0, blockAlign, ...options }) {
    const body = samples(frames, channels, bits, { float: code === 3, le: true, unsigned: bits === 8 });
    const align = blockAlign ?? channels * bits / 8;
    const format = [u16(extensible ? 0xfffe : code, true), u16(channels, true), u32(rate, true), u32(rate * align, true), u16(align, true), u16(bits, true)];
    if (extensible) {
        // cbSize 22、有効ビット、チャンネルマスク、SubFormat の GUID（先頭 2 バイトが形式）。
        format.push(u16(22, true), u16(bits, true), u32(3, true), u16(code, true),
            Uint8Array.of(0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71));
    }
    const chunks = [...extra, chunk('fmt ', concat(format), true), chunk('data', body.subarray(0, body.length - dataTrim), true)];
    const rest = concat([ascii('WAVE'), ...chunks]);
    return concat([ascii('RIFF'), u32(rest.length, true), rest]);
}

// 80 bit の IEEE 拡張倍精度（AIFF の標本率）。整数だけ。
function extended(rate) {
    const exponent = Math.floor(Math.log2(rate));
    const mantissa = BigInt(rate) << BigInt(63 - exponent);
    const out = new Uint8Array(10);
    const view = new DataView(out.buffer);
    view.setUint16(0, 16383 + exponent);
    view.setBigUint64(2, mantissa);
    return out;
}

function aiff({ frames, channels, rate = 44100, bits, compression = null, extra = [], commFrames, ssndSkip = 0, bigRate = null, ...options }) {
    const le = compression === 'sowt';
    const float = compression ? compression.toLowerCase().startsWith('fl') : false;
    const body = samples(frames, channels, bits, { float, le, unsigned: false });
    const comm = [u16(channels, false), u32(commFrames ?? frames, false), u16(bits, false), bigRate ?? extended(rate)];
    if (compression) comm.push(ascii(compression), Uint8Array.of(0)); // 圧縮の名前は pascal 文字列（0 長でよい）
    const ssnd = concat([u32(ssndSkip, false), u32(0, false), new Uint8Array(ssndSkip), body]);
    const kind = compression ? 'AIFC' : 'AIFF';
    const rest = concat([ascii(kind), ...extra, chunk('COMM', concat(comm), false), chunk('SSND', ssnd, false)]);
    return concat([ascii('FORM'), u32(rest.length, false), rest]);
}

// SF2 の smpl（Int16 LE）と sm24（下位バイト）。ファイルの中で、前後に余白を置いた別の位置にある。
function sf2Pcm(frames, withLow) {
    const high = new Uint8Array(frames * 2), low = new Uint8Array(frames);
    const view = new DataView(high.buffer);
    for (let frame = 0; frame < frames; frame++) {
        view.setInt16(frame * 2, integer(frame, 0, 16, false), true);
        low[frame] = ((frame * 97 + 13) & 255);
    }
    const pre = new Uint8Array(13).fill(0xee), gap = new Uint8Array(7).fill(0xdd);
    const file = concat([pre, high, gap, low]);
    return { file, pcm: { format: 'sf2-pcm', channels: 1, frames, sampleRate: 44100, dataOffset: 13, lowByteOffset: withLow ? 13 + frames * 2 + 7 : null } };
}

// 2 ページ目が短い（4096 + 137）。1 ページ目がちょうど 1 つ分と、短い 2 ページ目の両方を通す。
const FRAMES = SFZ_SAMPLE_PAGE_FRAMES + 137;
const oddChunk = chunk('LIST', ascii('abcde'), true);
const oddAiffChunk = chunk('NAME', ascii('abc'), false);

const cases = [
    { name: 'wav16-mono', file: wav({ frames: FRAMES, channels: 1, bits: 16 }) },
    { name: 'wav16-stereo-odd-chunk', file: wav({ frames: FRAMES, channels: 2, bits: 16, extra: [oddChunk] }) },
    { name: 'wav8-unsigned-mono', file: wav({ frames: FRAMES, channels: 1, bits: 8 }) },
    { name: 'wav24-stereo', file: wav({ frames: FRAMES, channels: 2, bits: 24 }) },
    { name: 'wav32-int-mono', file: wav({ frames: FRAMES, channels: 1, bits: 32 }) },
    { name: 'wav-float32-stereo', file: wav({ frames: FRAMES, channels: 2, bits: 32, code: 3 }) },
    { name: 'wav-float64-mono', file: wav({ frames: FRAMES, channels: 1, bits: 64, code: 3 }) },
    { name: 'wav-extensible-16', file: wav({ frames: FRAMES, channels: 2, bits: 16, extensible: true }) },
    { name: 'wav-extensible-float32', file: wav({ frames: FRAMES, channels: 1, bits: 32, code: 3, extensible: true }) },
    { name: 'aiff16-mono', file: aiff({ frames: FRAMES, channels: 1, bits: 16, extra: [oddAiffChunk] }) },
    { name: 'aiff8-signed-mono', file: aiff({ frames: FRAMES, channels: 1, bits: 8 }) },
    { name: 'aiff24-stereo', file: aiff({ frames: FRAMES, channels: 2, bits: 24, rate: 48000 }) },
    { name: 'aiff32-mono', file: aiff({ frames: FRAMES, channels: 1, bits: 32 }) },
    { name: 'aifc-sowt-16-stereo', file: aiff({ frames: FRAMES, channels: 2, bits: 16, compression: 'sowt' }) },
    { name: 'aifc-twos-16-mono', file: aiff({ frames: FRAMES, channels: 1, bits: 16, compression: 'twos' }) },
    { name: 'aifc-fl32-mono', file: aiff({ frames: FRAMES, channels: 1, bits: 32, compression: 'fl32' }) },
    { name: 'aifc-fl64-stereo', file: aiff({ frames: FRAMES, channels: 2, bits: 64, compression: 'FL64' }) },
    { name: 'aiff-ssnd-skip', file: aiff({ frames: FRAMES, channels: 1, bits: 16, ssndSkip: 6 }) },
    { name: 'exact-one-page-mono', file: wav({ frames: SFZ_SAMPLE_PAGE_FRAMES, channels: 1, bits: 16 }) },
    // 頭が通らないもの（上流の sample-format / sample-range）。
    { name: 'error-alaw', file: wav({ frames: 100, channels: 1, bits: 8, code: 6 }) },
    { name: 'error-12-bit', file: wav({ frames: 100, channels: 1, bits: 12, blockAlign: 2 }) },
    { name: 'error-3-channels', file: wav({ frames: 100, channels: 3, bits: 16 }) },
    { name: 'error-partial-frame', file: wav({ frames: 100, channels: 2, bits: 16, dataTrim: 1 }) },
    { name: 'error-aiff-frames-mismatch', file: aiff({ frames: 100, channels: 1, bits: 16, commFrames: 99 }) },
    { name: 'error-float-16', file: wav({ frames: 100, channels: 1, bits: 16, code: 3 }) },
    { name: 'error-aiff-negative-rate', file: aiff({ frames: 100, channels: 1, bits: 16, bigRate: Uint8Array.of(0xc0, 0x0e, 0xac, 0x44, 0, 0, 0, 0, 0, 0) }) },
    { name: 'error-not-audio', file: ascii('hello world, this is not an audio file at all') },
    // SF2 の PCM（頭は SF2 のパーサが決めるので、位置は入力としてそのまま渡す）。
    { name: 'sf2-with-sm24', ...sf2Pcm(FRAMES, true) },
    { name: 'sf2-without-sm24', ...sf2Pcm(FRAMES, false) },
    { name: 'sf2-exact-two-pages', ...sf2Pcm(SFZ_SAMPLE_PAGE_FRAMES * 2, true) }
];

const b64 = bytes => Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString('base64');

for (const item of cases) {
    const read = async (offset, length) => item.file.slice(offset, offset + length);
    let stream;
    try {
        stream = await SfzSampleStream.open(read, item.file.length, item.pcm ?? null);
    } catch (error) {
        item.error = error.code;
        item.file = b64(item.file);
        continue;
    }
    const m = stream.metadata;
    item.metadata = m.format === 'pcm'
        ? { format: 'pcm', frames: m.frames, channels: m.channels, sampleRate: m.sampleRate, dataOffset: m.dataOffset,
            blockAlign: m.blockAlign, bitsPerSample: m.bitsPerSample, float: m.float, littleEndian: m.littleEndian, unsigned: m.unsigned }
        : { format: m.format, frames: m.frames, channels: m.channels, sampleRate: m.sampleRate, dataOffset: m.dataOffset,
            lowByteOffset: m.lowByteOffset };
    item.pages = [];
    for (let page = 0; page * SFZ_SAMPLE_PAGE_FRAMES < m.frames; page++) {
        const result = await stream.readPage(page);
        item.pages.push({ page, frames: result.frames, channels: result.channels, f32: b64(result.pcm) });
    }
    item.file = b64(item.file);
    delete item.pcm;
}

const golden = {
    note: 'Tools/golden/sample_page_golden.mjs が上流の js/sfz/sample-stream.js に作らせた。手で直さない。',
    pageFrames: SFZ_SAMPLE_PAGE_FRAMES,
    cases
};
fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, JSON.stringify(golden, null, 1) + '\n');
const bytes = fs.statSync(outFile).size;
console.log('wrote', outFile, `(${cases.length} cases, ${cases.filter(c => c.error).length} errors, ${bytes} bytes)`);
