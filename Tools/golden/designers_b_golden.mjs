// designers_b_golden.mjs
// Group Delay EQ / Group Delay PEQ / Crosstalk Cancellation / Room EQ の設計と、
// Crosstalk の測定取り込みが使う onset の見本を、上流の design-core.js そのものに作らせる。
//
//   root=$(bash Tools/golden/extract_pin.sh)
//   EFFETUNE_ROOT="$root" node Tools/golden/designers_b_golden.mjs
//
// 書き出し先は Tests/Fixtures/Designers/designers-b-golden.json。Swift 側は入力を読んで
// 同じ設計に通し、答えと照合する（Tests/Unit/{GroupDelayEQ,GroupDelayPEQ,Crosstalk,RoomEQ}DesignTests.swift、
// CrosstalkMeasurementTests.swift）。
//
// --- FFT の回転因子だけは double にする ---
// 上流の js/utils/measurement-dsp/fft.js は回転因子（cosTable / sinTable）を Float32Array に
// 持っている。Swift 側（FIRDesign.RealFFT）は vDSP の Double 版なので、そのまま比べると
// 1 回の変換ごとに 1e-7 ほどずれ、設計の中身が合っているかどうかが丸めに埋もれる。
// そこで FFT.prototype の transform と realTransform の入口で、同じ式（-2πk/N の cos/sin）を
// Float64Array で作り直した表に差し替える。**それ以外は上流のコードをそのまま呼ぶ。**
// 見本が確かめるのは「設計の手順が上流と同じか」で、上流の FFT の精度ではない。
//
// --- 形 ---
// 数の並びは base64（リトルエンディアン）で、{"f32": "..."} か {"f64": "..."} で包む。
// f32 は上流が Float32Array に入れた値（係数・整列後の応答）、f64 は Float64Array の値。
// NaN も落とさずに運べる（検査の「有限でない」を試すのに使う）。
// 鍵は並べ替えて書くので、同じ入力なら何度作っても同じファイルになる。

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.join(here, '..', '..');
const root = process.env.EFFETUNE_ROOT
    ? path.resolve(process.env.EFFETUNE_ROOT)
    : path.join(repo, 'Vendor', 'effetune');
const outFile = path.join(repo, 'Tests', 'Fixtures', 'Designers', 'designers-b-golden.json');

const load = relative => import(pathToFileURL(path.join(root, relative)).href);

const { default: FFT } = await load('js/utils/measurement-dsp/fft.js');
const groupDelayEq = await load('js/group-delay-eq/design-core.js');
const groupDelayPeq = await load('js/group-delay-peq/design-core.js');
const crosstalk = await load('js/crosstalk-cancellation/design-core.js');
const roomEq = await load('js/room-eq/design-core.js');
const onset = await load('js/utils/measurement-dsp/onset.js');
const upstreamVersion = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version;

// ---- 回転因子を double に（上の説明） ----

const doubleTwiddles = new Map();
function useDoubleTwiddles(fft) {
    if (fft.cosTable instanceof Float64Array) return;
    let table = doubleTwiddles.get(fft.size);
    if (!table) {
        const cos = new Float64Array(fft.size);
        const sin = new Float64Array(fft.size);
        for (let index = 0; index < fft.size; index += 1) {
            const angle = -2 * Math.PI * index / fft.size;
            cos[index] = Math.cos(angle);
            sin[index] = Math.sin(angle);
        }
        table = { cos, sin };
        doubleTwiddles.set(fft.size, table);
    }
    fft.cosTable = table.cos;
    fft.sinTable = table.sin;
}
for (const name of ['transform', 'realTransform']) {
    const original = FFT.prototype[name];
    FFT.prototype[name] = function patched(...args) {
        useDoubleTwiddles(this);
        return original.apply(this, args);
    };
}

// ---- 包み方 ----

function f32(values) {
    const array = Float32Array.from(values);
    return { f32: Buffer.from(array.buffer, array.byteOffset, array.byteLength).toString('base64') };
}

function f64(values) {
    const array = Float64Array.from(values);
    return { f64: Buffer.from(array.buffer, array.byteOffset, array.byteLength).toString('base64') };
}

function sortKeys(value) {
    if (Array.isArray(value)) return value.map(sortKeys);
    if (value && typeof value === 'object') {
        return Object.fromEntries(Object.keys(value).sort().map(key => [key, sortKeys(value[key])]));
    }
    return value;
}

// 決まった乱数。-1〜1。
function lcg(seed) {
    let state = seed >>> 0;
    return () => {
        state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
        return state / 4294967296 * 2 - 1;
    };
}

// ---- Group Delay EQ ----

const gdeqSmall = [0, 0.5, 1, 2, 1, 0, -1, -2, -1, 0, 0.3, 0.6, 0.2, 0, 0];
const gdeqClamped = [30, 30, 25, 20, 0, -5, -40, 0, 0, 0, 0, 0, 0, 0, 5];
const gdeqLow = [5, 4, 3, 2, 1, 0.5, 0.25, 0, 0, 0, 0, 0, 0, 0, 0];

const groupDelayEqTargets = [
    { name: 'small-4096-48k', delaysMs: gdeqSmall, taps: 4096, sampleRate: 48000 },
    // taps 4096 / 48kHz の上限は 37.33ms。-40 が切られる。
    { name: 'clamped-4096-48k', delaysMs: gdeqClamped, taps: 4096, sampleRate: 48000 },
    // 3 本しか渡さない（残りは 0）。格子は自前で、0 Hz・帯の外・フェードの前後を含む。
    {
        name: 'short-8192-44k1-grid',
        delaysMs: [1, 2, 3],
        taps: 8192,
        sampleRate: 44100,
        frequencies: [0, 5, 20, 25, 30, 1000, 15000, 16000, 17000, 19000, 19845, 19846, 25000]
    },
    { name: 'low-32768-96k', delaysMs: gdeqLow, taps: 32768, sampleRate: 96000 }
].map(entry => ({
    ...entry,
    frequencies: entry.frequencies ? f64(entry.frequencies) : null,
    expected: f64(groupDelayEq.groupDelayTargetMs({
        delaysMs: entry.delaysMs,
        taps: entry.taps,
        sampleRate: entry.sampleRate,
        frequencies: entry.frequencies ? Float64Array.from(entry.frequencies) : undefined
    }))
}));

function groupDelayResult(result) {
    return {
        ir: f32(result.ir),
        bulkDelaySamples: result.bulkDelaySamples,
        clamped: result.clamped,
        limitMs: result.limitMs,
        rippleDb: result.rippleDb,
        frequencies: f64(result.response.frequencies),
        targetMs: f64(result.response.targetMs),
        realizedMs: f64(result.response.realizedMs)
    };
}

const groupDelayEqDesigns = [
    { name: 'small-4096-48k', delaysMs: gdeqSmall, taps: 4096, sampleRate: 48000 },
    { name: 'clamped-4096-48k', delaysMs: gdeqClamped, taps: 4096, sampleRate: 48000 },
    { name: 'low-4096-96k', delaysMs: gdeqLow, taps: 4096, sampleRate: 96000 }
].map(entry => ({
    ...entry,
    expected: groupDelayResult(groupDelayEq.designGroupDelayFilter({
        delaysMs: entry.delaysMs,
        taps: entry.taps,
        sampleRate: entry.sampleRate
    }))
}));

// ---- Group Delay PEQ ----

const gdpeqMixed = [
    { type: 'pk', frequency: 100, delayMs: 2, q: 0.7, enabled: true },
    { type: 'ls', frequency: 300, delayMs: -1, q: 1, enabled: true },
    { type: 'hs', frequency: 3000, delayMs: 0.5, q: 0.5, enabled: true },
    // Q が 1/√3 以下なので群遅延は単調。極値は DC の平らな所。
    { type: 'fl', frequency: 1000, delayMs: 1.5, q: 0.4, enabled: true },
    { type: 'fl', frequency: 5000, delayMs: -0.8, q: 4, enabled: true }
];
// 周波数と Q の範囲外、限界を超えた遅延、0 ms、切ってあるバンド。
const gdpeqEdges = [
    { type: 'pk', frequency: 50, delayMs: 1000, q: 0.7, enabled: true },
    { type: 'ls', frequency: 30000, delayMs: 1, q: 0.7, enabled: true },
    { type: 'pk', frequency: 5, delayMs: 0.3, q: 1000, enabled: true },
    { type: 'hs', frequency: 1000, delayMs: 0, q: 0.7, enabled: true },
    { type: 'pk', frequency: 1000, delayMs: 5, q: 0.7, enabled: false }
];
// 2 本の山が重なって和が限界を超える（切られるのは和のほう）。
const gdpeqOverlap = [
    { type: 'pk', frequency: 100, delayMs: 30, q: 0.7, enabled: true },
    { type: 'pk', frequency: 110, delayMs: 30, q: 0.7, enabled: true }
];

const groupDelayPeqTargets = [
    { name: 'mixed-16384-48k', bands: gdpeqMixed, taps: 16384, sampleRate: 48000 },
    {
        name: 'edges-4096-44k1-grid',
        bands: gdpeqEdges,
        taps: 4096,
        sampleRate: 44100,
        frequencies: [0, 10, 20, 50, 1000, 19000, 19845, 30000]
    },
    { name: 'overlap-8192-96k', bands: gdpeqOverlap, taps: 8192, sampleRate: 96000 }
].map(entry => ({
    ...entry,
    frequencies: entry.frequencies ? f64(entry.frequencies) : null,
    expected: f64(groupDelayPeq.groupDelayPeqTargetMs({
        bands: entry.bands,
        taps: entry.taps,
        sampleRate: entry.sampleRate,
        frequencies: entry.frequencies ? Float64Array.from(entry.frequencies) : undefined
    }))
}));

const groupDelayPeqDesigns = [
    { name: 'mixed-4096-48k', bands: gdpeqMixed, taps: 4096, sampleRate: 48000 },
    { name: 'overlap-4096-48k', bands: gdpeqOverlap, taps: 4096, sampleRate: 48000 }
].map(entry => ({
    ...entry,
    expected: groupDelayResult(groupDelayPeq.designGroupDelayPeqFilter({
        bands: entry.bands,
        taps: entry.taps,
        sampleRate: entry.sampleRate
    }))
}));

// ---- Crosstalk Cancellation ----

function complexPair(value) {
    return [value.re, value.im];
}

const solveRandom = lcg(701);
const crosstalkSolveBin = [1e-6, 0.01, 1, 50, 0.3].map((beta, index) => {
    const scale = index === 4 ? 1e-3 : 1;
    const draw = () => ({ re: solveRandom() * scale, im: solveRandom() * scale });
    const input = {
        hLL: draw(), hLR: draw(), hRL: draw(), hRR: draw(),
        targetLL: draw(), targetRR: draw(), beta
    };
    const solution = crosstalk.solveRegularizedCrosstalkBin(input);
    return {
        name: `random-${index}`,
        hLL: complexPair(input.hLL),
        hLR: complexPair(input.hLR),
        hRL: complexPair(input.hRL),
        hRR: complexPair(input.hRR),
        targetLL: complexPair(input.targetLL),
        targetRR: complexPair(input.targetRR),
        beta,
        expected: {
            c11: complexPair(solution.c11),
            c21: complexPair(solution.c21),
            c12: complexPair(solution.c12),
            c22: complexPair(solution.c22)
        }
    };
});

const smoothRandom = lcg(811);
const crosstalkSmooth = [
    { name: 'fft64-delay-default', fftSize: 64, sampleRate: 48000, delaySeconds: 0.0003 },
    { name: 'fft64-delay-half-octave', fftSize: 64, sampleRate: 48000, delaySeconds: 0.0003, smoothingOctaves: 0.5 },
    { name: 'fft64-no-smoothing', fftSize: 64, sampleRate: 44100, delaySeconds: 0.001, smoothingOctaves: 0 },
    { name: 'fft256-no-delay', fftSize: 256, sampleRate: 96000, delaySeconds: 0 }
].map(entry => {
    const length = entry.fftSize / 2 + 1;
    const real = Float64Array.from({ length }, () => smoothRandom());
    const imag = Float64Array.from({ length }, () => smoothRandom());
    const result = entry.smoothingOctaves === undefined
        ? crosstalk.smoothDelayCompensatedSpectrum({ real, imag }, entry.sampleRate, entry.fftSize,
            entry.delaySeconds)
        : crosstalk.smoothDelayCompensatedSpectrum({ real, imag }, entry.sampleRate, entry.fftSize,
            entry.delaySeconds, entry.smoothingOctaves);
    return {
        name: entry.name,
        fftSize: entry.fftSize,
        sampleRate: entry.sampleRate,
        delaySeconds: entry.delaySeconds,
        smoothingOctaves: entry.smoothingOctaves ?? null,
        real: f64(real),
        imag: f64(imag),
        expected: { real: f64(result.real), imag: f64(result.imag) }
    };
});

// 片耳の測定。直接音（onset）と、少し遅れて小さい向こう側のスピーカー、減衰する雑音。
function earResponse({ frames, onset: at, gain, seed, decay = 120 }) {
    const random = lcg(seed);
    const out = new Float32Array(frames);
    for (let index = at; index < frames; index += 1) {
        out[index] = gain * 0.25 * random() * Math.exp(-(index - at) / decay);
    }
    out[at] += gain;
    if (at + 1 < frames) out[at + 1] -= gain * 0.4;
    return out;
}

// 入力の測定。Swift の Measurement と同じ項目を持つ。
function measurement({ id, data, sampleRate, trimStartSamples = 0, onsetIndex, refScale = 1,
    timeReference = 'audio-context' }) {
    return { id, data: Float32Array.from(data), sampleRate, trimStartSamples, onsetIndex, refScale, timeReference };
}

function crosstalkSources({ rate, frames, left = 'left-ear', right = 'right-ear', trim = [0, 0, 0, 0],
    refScale = [1, 1, 1, 1] }) {
    const directOnset = Math.round(rate * 0.004);
    const crossOnset = directOnset + Math.round(rate * 0.00025);
    return {
        ll: measurement({ id: `${left}::ch=left`, data: earResponse({ frames, onset: directOnset, gain: 0.9, seed: 11 }),
            sampleRate: rate, trimStartSamples: trim[0], onsetIndex: directOnset, refScale: refScale[0] }),
        lr: measurement({ id: `${right}::ch=left`, data: earResponse({ frames, onset: crossOnset, gain: 0.35, seed: 12 }),
            sampleRate: rate, trimStartSamples: trim[1], onsetIndex: crossOnset, refScale: refScale[1] }),
        rl: measurement({ id: `${left}::ch=right`, data: earResponse({ frames, onset: crossOnset, gain: 0.3, seed: 13 }),
            sampleRate: rate, trimStartSamples: trim[2], onsetIndex: crossOnset, refScale: refScale[2] }),
        rr: measurement({ id: `${right}::ch=right`, data: earResponse({ frames, onset: directOnset, gain: 0.8, seed: 14 }),
            sampleRate: rate, trimStartSamples: trim[3], onsetIndex: directOnset, refScale: refScale[3] })
    };
}

// 上流の入力の形へ（sourceRecord が読む形）。
function upstreamSources(sources) {
    return Object.fromEntries(Object.entries(sources).map(([slot, m]) => [slot, {
        id: m.id,
        impulses: [{
            data: m.data,
            sampleRate: m.sampleRate,
            trimStartSamples: m.trimStartSamples,
            onsetIndex: m.onsetIndex,
            refScale: m.refScale,
            outputTimeReference: m.timeReference
        }]
    }]));
}

function encodeSources(sources) {
    return Object.fromEntries(Object.entries(sources).map(([slot, m]) => [slot, {
        id: m.id,
        data: f32(m.data),
        sampleRate: m.sampleRate,
        trimStartSamples: m.trimStartSamples,
        onsetIndex: m.onsetIndex,
        referenceScale: m.refScale,
        timeReference: m.timeReference
    }]));
}

// 検査だけを見るので、中身は短くてよい（onset が長さを超えていても検査は見ない）。
const validBase = crosstalkSources({ rate: 48000, frames: 12 });
function variant(changes) {
    const copy = Object.fromEntries(Object.entries(validBase).map(([slot, m]) => [slot, { ...m }]));
    for (const [slot, fields] of Object.entries(changes)) Object.assign(copy[slot], fields);
    return copy;
}
const crosstalkValidate = [
    { name: 'ok-trimmed-ids', sources: variant({ ll: { id: '  left-ear::ch=left ' } }) },
    { name: 'duplicate-ids', sources: variant({ lr: { id: 'left-ear::ch=left' } }) },
    { name: 'left-ear-mismatch', sources: variant({ rl: { id: 'other::ch=right' } }) },
    { name: 'right-ear-mismatch', sources: variant({ rr: { id: 'other::ch=right' } }) },
    { name: 'separator-at-start', sources: variant({ ll: { id: '::ch=left' }, rl: { id: '::ch=right' } }) },
    { name: 'sample-rate-mismatch', sources: variant({ rr: { sampleRate: 44100 } }) },
    { name: 'missing-id', sources: variant({ rl: { id: '   ' } }) },
    { name: 'media-element', sources: variant({ lr: { timeReference: 'media-element' } }) },
    { name: 'negative-onset', sources: variant({ rr: { onsetIndex: -1 } }) },
    { name: 'zero-rate', sources: variant({ ll: { sampleRate: 0 } }) },
    { name: 'empty-data', sources: variant({ rl: { data: new Float32Array(0) } }) },
    { name: 'nan-data', sources: variant({ lr: { data: Float32Array.from([0, Number.NaN, 0]) } }) },
    // 先に見つかった枠の失敗が勝つ（ll → lr → rl → rr の順）。
    { name: 'first-slot-wins', sources: variant({ lr: { onsetIndex: -1 }, rl: { id: '' } }) }
].map(entry => {
    let expected;
    try {
        const result = crosstalk.validateCrosstalkSources(upstreamSources(entry.sources));
        expected = {
            code: null,
            sampleRate: result.sampleRate,
            ids: Object.fromEntries(Object.entries(result.sources).map(([slot, s]) => [slot, s.id]))
        };
    } catch (error) {
        if (!(error instanceof crosstalk.CrosstalkCancellationDesignError)) throw error;
        expected = { code: error.code, slot: error.slot ?? null, message: error.message };
    }
    return { name: entry.name, sources: encodeSources(entry.sources), expected };
});

const crosstalkDesigns = [
    {
        // 測定 44.1kHz → 設計 48kHz（リサンプラを通る）。
        name: 'resampled-1024',
        config: { sampleRate: 48000, taps: 1024, regularization: 50, maxGainDb: 12,
            lowFrequency: 200, highFrequency: 6000, directWindowMs: 8 },
        sources: crosstalkSources({ rate: 44100, frames: 640 })
    },
    {
        // 範囲外の設定（倒し方）、記録の頭のずれ、基準の倍率。
        name: 'normalized-edges',
        config: { sampleRate: 48000, taps: 1024, regularization: 150, maxGainDb: 30,
            lowFrequency: 10, highFrequency: 25000, directWindowMs: 1 },
        sources: crosstalkSources({ rate: 48000, frames: 420, trim: [5, 40, 0, 12],
            refScale: [2.5, 1, 0, 1] })
    },
    {
        // 利得の上限 0 dB で頭打ちが効く。
        name: 'gain-limited-96k',
        config: { sampleRate: 96000, taps: 1024, regularization: 0, maxGainDb: 0,
            lowFrequency: 300, highFrequency: 12000, directWindowMs: 5 },
        sources: crosstalkSources({ rate: 48000, frames: 520, left: 'L', right: 'R' })
    },
    {
        // 測定 96kHz → 設計 48kHz。間引く側（bandLimit = 48/96、位相は 1 つ）。
        name: 'downsampled-96k-to-48k',
        config: { sampleRate: 48000, taps: 1024, regularization: 50, maxGainDb: 12,
            lowFrequency: 200, highFrequency: 6000, directWindowMs: 8 },
        sources: crosstalkSources({ rate: 96000, frames: 1280 })
    },
    {
        // 測定 192kHz → 設計 44.1kHz。間引く側で位相が 147 ある（640:147）。
        name: 'downsampled-192k-to-44k1',
        config: { sampleRate: 44100, taps: 1024, regularization: 50, maxGainDb: 12,
            lowFrequency: 200, highFrequency: 8000, directWindowMs: 5 },
        sources: crosstalkSources({ rate: 192000, frames: 2560 })
    }
].map(entry => {
    const result = crosstalk.designCrosstalkCancellation({
        config: entry.config,
        sources: upstreamSources(entry.sources)
    });
    return {
        name: entry.name,
        config: entry.config,
        sources: encodeSources(entry.sources),
        expected: {
            channels: result.channels.map(f32),
            config: {
                sampleRate: result.config.sampleRate,
                taps: result.config.taps,
                filterDelaySamples: result.config.filterDelaySamples,
                regularization: result.config.regularization,
                maxGainDb: result.config.maxGainDb,
                lowFrequency: result.config.lowFrequency,
                highFrequency: result.config.highFrequency,
                directWindowMs: result.config.directWindowMs
            },
            diagnostics: result.diagnostics
        }
    };
});

// ---- Room EQ ----

const roomEqSoftLimit = [];
for (const [maximum, values] of [
    [6, [-3, 0, 4.9, 5, 5.2, 5.5, 5.99, 6, 7, 12]],
    [0, [-2, -1, -0.5, -0.25, 0, 1]],
    [18, [16.9, 17, 17.3, 17.75, 18, 18.5]]
]) {
    for (const decibels of values) {
        roomEqSoftLimit.push({ decibels, maximum, expected: roomEq.softLimitBoost(decibels, maximum) });
    }
}

// 1/12 オクターブの周波数特性。低域の山、中域の谷、高域の下がり。
function roomCurve() {
    const points = [];
    for (let frequency = 15; frequency <= 22000; frequency *= 2 ** (1 / 12)) {
        const octaves = Math.log2(frequency / 1000);
        const decibels = 6 * Math.exp(-((Math.log2(frequency / 55)) ** 2) / 0.3)
            - 4 * Math.exp(-((Math.log2(frequency / 400)) ** 2) / 0.1)
            - (octaves > 2 ? 3 * (octaves - 2) : 0)
            + 0.8 * Math.sin(octaves * 5);
        points.push([frequency, decibels]);
    }
    return points;
}

function roomImpulse({ frames, lead, seed, decay }) {
    const random = lcg(seed);
    const out = new Float32Array(frames);
    out[lead] = 1;
    for (let index = lead + 1; index < frames; index += 1) {
        out[index] = 0.5 * random() * Math.exp(-(index - lead) / decay);
    }
    return out;
}

const eqBands = [
    { enabled: true, type: 'pk', frequency: 1000, gain: -3, q: 1.4 },
    { enabled: true, type: 'ls', frequency: 120, gain: 2, q: 0.7 },
    { enabled: true, type: 'hs', frequency: 8000, gain: -1.5, q: 0.7 },
    { enabled: false, type: 'pk', frequency: 3000, gain: 6, q: 1 },
    { enabled: true, type: 'pk', frequency: 5000, gain: 0, q: 1 }
];

const roomEqDesigns = [
    {
        // 周波数特性だけの測定・最小位相・Additional EQ。2 本目は測定なし（素通し）。
        name: 'response-min-8192',
        config: { sampleRate: 48000, taps: 8192, phase: 'min', smoothing: 0.17, lowFrequency: 40,
            highFrequency: 16000, maxBoostDb: 6, correctionAmount: 1, eqBands },
        sources: [{ frequencyResponse: roomCurve() }, null]
    },
    {
        // インパルス応答 2 本（44.1kHz → 48kHz、片方は基準の倍率つき）・直線位相。
        name: 'impulses-lin-8192',
        config: { sampleRate: 48000, taps: 8192, phase: 'lin', smoothing: 0.3, lowFrequency: 30,
            highFrequency: 18000, maxBoostDb: 3, correctionAmount: 0.6, eqBands: [] },
        sources: [{
            impulses: [
                { data: roomImpulse({ frames: 1400, lead: 20, seed: 31, decay: 300 }), sampleRate: 44100,
                    onsetIndex: 20, refScale: 1 },
                { data: roomImpulse({ frames: 1100, lead: 35, seed: 32, decay: 200 }), sampleRate: 44100,
                    onsetIndex: 35, refScale: 3 }
            ]
        }]
    },
    {
        // 同じレートのインパルス応答 1 本・最小位相・範囲外の設定（倒し方）。
        // 35Hz の鋭い谷は 8192 taps では追いきれず、filterAccuracy の注意が出る。
        name: 'impulse-min-edges',
        config: { sampleRate: 44100, taps: 8192, phase: 'min', smoothing: 5, lowFrequency: 5,
            highFrequency: 30000, maxBoostDb: 40, correctionAmount: 2,
            eqBands: [{ enabled: true, type: 'pk', frequency: 35, gain: -12, q: 8 }] },
        sources: [{
            impulses: [{ data: roomImpulse({ frames: 1600, lead: 0, seed: 41, decay: 400 }), sampleRate: 44100,
                onsetIndex: 0, refScale: 1 }]
        }]
    },
    {
        // 間引く側のインパルス応答 2 本（96kHz → 48kHz は位相 1 つ、88.2kHz → 48kHz は 147:80）・最小位相。
        // 2 本目の枠は 96kHz 1 本だけ。
        name: 'impulses-downsampled-min',
        config: { sampleRate: 48000, taps: 8192, phase: 'min', smoothing: 0.17, lowFrequency: 30,
            highFrequency: 16000, maxBoostDb: 6, correctionAmount: 0.8, eqBands: [] },
        sources: [{
            impulses: [
                { data: roomImpulse({ frames: 2800, lead: 40, seed: 51, decay: 600 }), sampleRate: 96000,
                    onsetIndex: 40, refScale: 1 },
                { data: roomImpulse({ frames: 2600, lead: 30, seed: 52, decay: 500 }), sampleRate: 88200,
                    onsetIndex: 30, refScale: 2 }
            ]
        }, {
            impulses: [{ data: roomImpulse({ frames: 3000, lead: 10, seed: 53, decay: 700 }), sampleRate: 96000,
                onsetIndex: 10, refScale: 1 }]
        }]
    }
].map(entry => {
    const upstream = entry.sources.map((source, index) => {
        if (!source) return null;
        if (source.impulses) {
            return {
                measurement: { id: `${entry.name}-${index}` },
                impulses: source.impulses.map((impulse, pointId) => ({ ...impulse, pointId }))
            };
        }
        return { measurement: { id: `${entry.name}-${index}`, averageFrequencyResponse: source.frequencyResponse } };
    });
    const result = roomEq.designRoomEq({ config: entry.config, sources: upstream });
    return {
        name: entry.name,
        config: entry.config,
        sources: entry.sources.map(source => {
            if (!source) return null;
            if (source.impulses) {
                return {
                    impulses: source.impulses.map(impulse => ({
                        data: f32(impulse.data),
                        sampleRate: impulse.sampleRate,
                        onsetIndex: impulse.onsetIndex,
                        referenceScale: impulse.refScale
                    })),
                    frequencyResponse: []
                };
            }
            return {
                impulses: [],
                frequencyResponse: source.frequencyResponse.map(([frequency, decibels]) => ({ frequency, decibels }))
            };
        }),
        expected: {
            channels: result.channels.map(f32),
            filterDelaySamples: result.latencyInfo.filterDelaySamples,
            resolutionHz: result.latencyInfo.resolutionHz,
            supportsFullPhase: result.supportsFullPhase,
            qualityWarnings: [...new Set(result.qualityWarnings)],
            referenceLevelDb: result.previews.map(preview => preview ? preview.referenceLevelDb : null),
            // 画面の曲線（Sources/EffeTuneLive/DSP/Designers/RoomEQPreview.swift が写したもの）。
            // 格子は Swift 側でも同じ式で作るので、長さだけ照らす（frequencyCount）。
            previews: result.previews.map(preview => preview ? {
                frequencyCount: preview.frequencies.length,
                measuredDb: f32(preview.measuredDb),
                baseCorrectionDb: f32(preview.baseCorrectionDb),
                predictedBaseDb: f32(preview.predictedBaseDb),
                phase: preview.phaseResponse ? {
                    before: f32(preview.phaseResponse.before),
                    after: f32(preview.phaseResponse.after)
                } : null,
                minimumGroupDelay: preview.groupDelayResponse ? {
                    before: f32(preview.groupDelayResponse.minimum.before),
                    after: f32(preview.groupDelayResponse.minimum.after)
                } : null,
                excessGroupDelay: preview.groupDelayResponse ? {
                    before: f32(preview.groupDelayResponse.excess.before),
                    after: f32(preview.groupDelayResponse.excess.after)
                } : null,
                impulse: preview.impulseResponse ? {
                    startMs: preview.impulseResponse.startMs,
                    durationMs: preview.impulseResponse.durationMs,
                    before: f32(preview.impulseResponse.before),
                    after: f32(preview.impulseResponse.after)
                } : null
            } : null),
            config: {
                sampleRate: result.config.sampleRate,
                taps: result.config.taps,
                smoothing: result.config.smoothing,
                lowFrequency: result.config.lowFrequency,
                highFrequency: result.config.highFrequency,
                maxBoostDb: result.config.maxBoostDb,
                correctionAmount: result.config.correctionAmount
            }
        }
    };
});

// ---- onset（Crosstalk の測定取り込み） ----

function onsetCase(name, samples, sampleRate) {
    return { name, samples: f32(samples), sampleRate, expected: onset.detectOnset(Float32Array.from(samples), sampleRate) };
}
const onsetRandom = lcg(911);
const onsetCases = [
    onsetCase('impulse-lead-100', Float32Array.from({ length: 600 }, (_, i) => (i === 100 ? 0.8 : 0)), 48000),
    onsetCase('all-zero', new Float32Array(300), 48000),
    onsetCase('empty', new Float32Array(0), 48000),
    // 1e-11 の床は無音とみなされる（エネルギー 1e-22 <= 1e-20）。
    onsetCase('floor-then-ramp', Float32Array.from({ length: 800 }, (_, i) => (i < 200 ? 1e-11
        : Math.min(1, (i - 200) / 50) * Math.sin(i))), 44100),
    // 8kHz では窓が 8 に倒れる。
    onsetCase('noise-8k', Float32Array.from({ length: 400 }, (_, i) => (i < 60 ? 0.001 * onsetRandom()
        : onsetRandom() * Math.exp(-(i - 60) / 40))), 8000),
    onsetCase('late-peak-96k', Float32Array.from({ length: 1000 }, (_, i) => (i < 10 ? 0
        : 0.02 * onsetRandom() + (i === 900 ? 1 : 0))), 96000)
];

const golden = {
    about: 'Tools/golden/designers_b_golden.mjs が上流の design-core.js に作らせた見本。FFT の回転因子だけ double（生成器の頭を参照）。',
    upstreamVersion,
    groupDelayEq: { targets: groupDelayEqTargets, designs: groupDelayEqDesigns },
    groupDelayPeq: { targets: groupDelayPeqTargets, designs: groupDelayPeqDesigns },
    crosstalk: {
        solveBin: crosstalkSolveBin,
        smooth: crosstalkSmooth,
        validate: crosstalkValidate,
        designs: crosstalkDesigns
    },
    roomEq: { softLimitBoost: roomEqSoftLimit, designs: roomEqDesigns },
    onset: onsetCases
};

fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, JSON.stringify(sortKeys(golden), null, 1) + '\n');
console.log(`wrote ${path.relative(repo, outFile)} (upstream ${upstreamVersion})`);
