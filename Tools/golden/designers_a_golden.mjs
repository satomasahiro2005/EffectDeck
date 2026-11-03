// designers_a_golden.mjs
// 5Band FIR PEQ・FIR Crossover・Bass Managementの設計の見本を、上流のコードそのものに作らせる。
//
//   root=$(bash Tools/golden/extract_pin.sh)
//   EFFETUNE_ROOT="$root" node Tools/golden/designers_a_golden.mjs
//
// 読むもの（EFFETUNE_ROOT、無ければVendor/effetune）:
//   js/five-band-fir-peq/design-core.js   fiveBandFirPeqMagnitude・designFiveBandFirPeq
//   js/fir-crossover/design-core.js       crossoverLowWeight・crossoverBandMagnitudes・
//                                         analyzeFIRAtFrequencies・designFIRCrossover
//   js/bass-management/design-core.js     normalizeBassManagementDesignConfig・designBassManagement
//   js/ir-library/ir-asset-payload.js     buildIrAssetPayload（design-worker.jsと同じ引数で呼ぶ）
//   plugins/basics/bass_management.js     _configurationError・_renderConfiguration・
//                                         _setSubOutputEnabled・_linearInputChannels
// 書くもの: Tests/Fixtures/Designers/designers-a-golden.json（鍵を並べ替えた決まった形）。
// Swift側はTests/Unit/{BandFIRPEQDesign,FIRCrossoverDesign,BassManagementDesign,
// BassManagementSettings}Tests.swiftが読んで照合する。
//
// --- FFTだけ差し替える ---
// 上流のjs/utils/measurement-dsp/fft.jsは回転因子をFloat32Arrayに持つので、答えが1e-7ほど
// ぶれる（本番のWorkerはさらにfloat32のWASMに差し替えている）。Swift（FIRDesign.RealFFT）は
// Doubleで回すので、そのままでは細かい食い違いが測れない。上流は設計の中身に触らずFFTだけを
// 替える口（setFiveBandFirPeqFftBackend・setFIRCrossoverFftBackend）を持っているので、
// ここでDoubleの基数2のFFTを差す。約束はfft.jsと同じ（前進は正規化なしでN/2+1個、
// 逆は1/Nを掛けた実部）。設計の手順・丸め・窓・Float32へ落とす位置は上流のまま。
//
// --- 5Band FIR PEQの最大誤差 ---
// designFiveBandFirPeqは最大誤差（maximumErrorDb）を返さないので、design-core.jsの本文を
// 評価し直した版から控える（下の「5Band FIR PEQの最大誤差を上流から取る」）。
//
// --- bass_management.jsの読み方 ---
// 画面のクラス（PluginBaseを継ぐただのscript）なので、PluginBaseの代役と空のwindowを渡して
// new Functionで評価し、判断だけをするメソッドを直に呼ぶ。_setSubOutputEnabledは最後に
// setParametersへ渡す値を横取りする（setParametersの検証とUIの更新は通さない）。

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.join(here, '..', '..');
const root = path.resolve(process.env.EFFETUNE_ROOT || path.join(repo, 'Vendor', 'effetune'));
const outFile = path.join(repo, 'Tests', 'Fixtures', 'Designers', 'designers-a-golden.json');

const load = rel => import(pathToFileURL(path.join(root, rel)).href);
const peq = await load('js/five-band-fir-peq/design-core.js');
const crossover = await load('js/fir-crossover/design-core.js');
const bass = await load('js/bass-management/design-core.js');
const assetPayload = await load('js/ir-library/ir-asset-payload.js');

// ---- DoubleのFFT（fft.jsと同じ約束） ----

const twiddleCache = new Map();
function twiddles(size) {
    let table = twiddleCache.get(size);
    if (!table) {
        const cos = new Float64Array(size / 2);
        const sin = new Float64Array(size / 2);
        for (let k = 0; k < size / 2; k += 1) {
            cos[k] = Math.cos(2 * Math.PI * k / size);
            sin[k] = Math.sin(2 * Math.PI * k / size);
        }
        table = { cos, sin };
        twiddleCache.set(size, table);
    }
    return table;
}

// 複素のFFT（その場で）。sign -1が前進（e^{-i}）、+1が逆（1/Nは掛けない）。
function complexFFT(re, im, sign) {
    const n = re.length;
    for (let i = 1, j = 0; i < n; i += 1) {
        let bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            [re[i], re[j]] = [re[j], re[i]];
            [im[i], im[j]] = [im[j], im[i]];
        }
    }
    const { cos, sin } = twiddles(n);
    for (let length = 2; length <= n; length <<= 1) {
        const half = length >> 1;
        const step = n / length;
        for (let start = 0; start < n; start += length) {
            for (let k = 0; k < half; k += 1) {
                const wr = cos[k * step];
                const wi = sign * sin[k * step];
                const a = start + k;
                const b = a + half;
                const tr = re[b] * wr - im[b] * wi;
                const ti = re[b] * wi + im[b] * wr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
            }
        }
    }
}

const doubleFFT = {
    realTransform(input) {
        const n = input.length;
        const re = Float64Array.from(input);
        const im = new Float64Array(n);
        complexFFT(re, im, -1);
        return { real: re.slice(0, n / 2 + 1), imag: im.slice(0, n / 2 + 1) };
    },
    inverseRealTransform(real, imag, size) {
        const re = new Float64Array(size);
        const im = new Float64Array(size);
        for (let k = 0; k <= size / 2; k += 1) {
            re[k] = real[k] || 0;
            im[k] = imag[k] || 0;
        }
        for (let k = 1; k < size / 2; k += 1) {
            re[size - k] = re[k];
            im[size - k] = -im[k];
        }
        complexFFT(re, im, 1);
        const out = new Float64Array(size);
        for (let i = 0; i < size; i += 1) out[i] = re[i] / size;
        return out;
    }
};
peq.setFiveBandFirPeqFftBackend(doubleFFT);
crossover.setFIRCrossoverFftBackend(doubleFFT);

// ---- 5Band FIR PEQの最大誤差を上流から取る ----
// 画面の「Accuracy is off by up to %.1f dB.」の数はmaximumErrorDbだが、designFiveBandFirPeqの
// 戻り値は警告の有無（qualityWarnings）しか持たない。design-core.jsの本文を読んで評価し直し、
// measureMagnitudeResponseの結果を1行で控える。書き換えは次の2か所だけで、どちらも1回ずつ当たる
// ことを確かめる: fft.jsのimportを絶対URLにする（data: URLからは相対で引けない）、控える1行を足す。
// 評価し直した版の係数と警告が元の版と一致することも下で確かめる（書き換えで設計が変わっていない）。
function replaceOnce(text, from, to) {
    const at = text.indexOf(from);
    if (at < 0 || text.indexOf(from, at + from.length) >= 0) {
        throw new Error(`five-band-fir-peq/design-core.js: 「${from}」が1か所でない（上流が変わった）`);
    }
    return text.slice(0, at) + to + text.slice(at + from.length);
}
const peqMeasureLine = 'const { maximumErrorDb, response } = measureMagnitudeResponse(taps, magnitudes, config);';
let peqProbeSource = fs.readFileSync(path.join(root, 'js', 'five-band-fir-peq', 'design-core.js'), 'utf8');
peqProbeSource = replaceOnce(peqProbeSource, "from '../utils/measurement-dsp/fft.js'",
    `from '${pathToFileURL(path.join(root, 'js', 'utils', 'measurement-dsp', 'fft.js')).href}'`);
peqProbeSource = replaceOnce(peqProbeSource, peqMeasureLine,
    `${peqMeasureLine}\n    probedMaximumErrorDb = maximumErrorDb;`);
peqProbeSource += '\nlet probedMaximumErrorDb = NaN;\n'
    + 'export function takeProbedMaximumErrorDb() {\n'
    + '    const value = probedMaximumErrorDb;\n'
    + '    probedMaximumErrorDb = NaN;\n'
    + '    return value;\n'
    + '}\n';
const peqProbe = await import('data:text/javascript;base64,' + Buffer.from(peqProbeSource).toString('base64'));

// 控えから返ると測り直さない（NaNのまま）ので、呼ぶたびにsetFiveBandFirPeqFftBackendで控えを空にする。
function probePeqMaximumErrorDb(candidate, expected) {
    peqProbe.setFiveBandFirPeqFftBackend(doubleFFT);
    const probed = peqProbe.designFiveBandFirPeq(candidate);
    const maximumErrorDb = peqProbe.takeProbedMaximumErrorDb();
    if (Number.isNaN(maximumErrorDb)) throw new Error('maximumErrorDb を控えられなかった');
    finite(maximumErrorDb, 'maximumErrorDb');
    const a = probed.channels[0];
    const b = expected.channels[0];
    if (a.length !== b.length || a.some((value, index) => !Object.is(value, b[index]))
        || JSON.stringify(probed.qualityWarnings) !== JSON.stringify(expected.qualityWarnings)) {
        throw new Error('評価し直したdesign-core.jsの設計が元と違う');
    }
    if ((maximumErrorDb > 0.5) !== (expected.qualityWarnings.length > 0)) {
        throw new Error('maximumErrorDb と qualityWarnings が食い違う');
    }
    return maximumErrorDb;
}

// ---- 道具 ----

function lcg(seed) {
    let state = seed >>> 0;
    return () => {
        state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
        return state / 4294967296;
    };
}

const plain = values => Array.from(values, Number);

// 係数の要約。全部は書かない（8192〜16384個×帯の数になる）。頭・真ん中・等間隔の点と和で見る。
function channelStats(channel) {
    const taps = channel.length;
    const pick = (start, count) => plain(channel.slice(start, start + count));
    const strideCount = 48;
    const stride = Math.floor(taps / strideCount);
    let sum = 0;
    let sumAbs = 0;
    let sumSquares = 0;
    let peakIndex = 0;
    for (let i = 0; i < taps; i += 1) {
        const v = channel[i];
        sum += v;
        sumAbs += Math.abs(v);
        sumSquares += v * v;
        if (Math.abs(v) > Math.abs(channel[peakIndex])) peakIndex = i;
    }
    return {
        taps,
        head: pick(0, 48),
        midStart: taps / 2 - 24,
        mid: pick(taps / 2 - 24, 48),
        stride,
        strided: Array.from({ length: strideCount }, (_, k) => channel[k * stride]),
        sum,
        sumAbs,
        sumSquares,
        peakIndex,
        peak: channel[peakIndex]
    };
}

function sortKeys(value) {
    if (Array.isArray(value)) return value.map(sortKeys);
    if (value && typeof value === 'object') {
        return Object.fromEntries(Object.keys(value).sort().map(key => [key, sortKeys(value[key])]));
    }
    return value;
}

function finite(value, what) {
    if (typeof value === 'number' && !Number.isFinite(value)) {
        throw new Error(`${what} が有限でない（JSONに書けない）`);
    }
    return value;
}

// ---- 5Band FIR PEQ ----

const peqTypes = ['pk', 'lp', 'hp', 'ls', 'hs', 'bp', 'no'];
const peqParameterSets = [
    { sampleRate: 48000, center: 1000, gain: 6, q: 0.7, slope: 12 },
    { sampleRate: 44100, center: 120, gain: -12.5, q: 4.3, slope: 36 },
    { sampleRate: 96000, center: 15000, gain: 20, q: 0.1, slope: 0.1 },
    { sampleRate: 48000, center: 30000, gain: -20, q: 100, slope: 384 },  // 中心が0.49·srで頭打ち
    { sampleRate: 192000, center: 20, gain: 0, q: 1.41, slope: 24 }
];
const peqProbeFrequencies = [1, 20, 63.5, 100, 440, 1000, 2500, 8000, 12345.6, 20000, 23999, 24000, 47000];
const peqMagnitude = [];
for (const type of peqTypes) {
    for (const set of peqParameterSets) {
        const frequencies = peqProbeFrequencies.filter(f => f < set.sampleRate / 2 + 1);
        peqMagnitude.push({
            type,
            ...set,
            frequencies,
            magnitudes: frequencies.map(f => finite(
                peq.fiveBandFirPeqMagnitude(type, f, { ...set }), 'peq magnitude'))
        });
    }
}

function peqBand(overrides) {
    return { enabled: true, type: 'pk', frequency: 1000, gain: 0, q: 0.7, slope: 12, ...overrides };
}

// Swiftの設定で書ける値だけを渡す（typeは7種のどれか、tapsは許された5つのどれか）。
const peqCases = [
    {
        name: 'min-peaks-48k',
        sampleRate: 48000, taps: 8192, phase: 'min',
        bands: [
            peqBand({ frequency: 100, gain: 6, q: 1 }),
            peqBand({ frequency: 316, gain: -3.5, q: 2.2 }),
            peqBand({ frequency: 1000, enabled: false, gain: 10 }),
            peqBand({ frequency: 3160, type: 'hs', gain: -6, q: 0.7 }),
            peqBand({ frequency: 10000, type: 'ls', gain: 4, q: 0.5 })
        ]
    },
    {
        name: 'lin-mixed-44k1',
        sampleRate: 44100, taps: 8192, phase: 'lin',
        bands: [
            peqBand({ frequency: 30, type: 'hp', q: 0.707, slope: 24 }),
            peqBand({ frequency: 250, type: 'bp', q: 3 }),
            peqBand({ frequency: 1000, type: 'no', q: 8 }),
            peqBand({ frequency: 4000, gain: 12, q: 6 }),
            peqBand({ frequency: 16000, type: 'lp', q: 0.5, slope: 48 })
        ]
    },
    {
        name: 'min-steep-96k',
        sampleRate: 96000, taps: 16384, phase: 'min',
        bands: [
            peqBand({ frequency: 60, type: 'hp', q: 0.9, slope: 96 }),
            peqBand({ frequency: 180, gain: -20, q: 12 }),
            peqBand({ frequency: 1200, gain: 20, q: 0.3 }),
            peqBand({ frequency: 7000, type: 'hs', gain: 8, q: 1.2 }),
            peqBand({ frequency: 19000, type: 'lp', q: 2, slope: 6 })
        ]
    },
    {
        // 正規化: 範囲外の周波数・利得・Q・slopeと、20kHzを超える中心（Nyquistの0.49倍で頭打ち）。
        name: 'lin-clamped-32k',
        sampleRate: 32000, taps: 8192, phase: 'lin',
        bands: [
            peqBand({ frequency: 5, gain: 40, q: 0.01, slope: 1000 }),
            peqBand({ frequency: 18000, gain: -35, q: 400, type: 'ls' }),
            peqBand({ frequency: 800, type: 'lp', slope: 0.01 }),
            peqBand({ frequency: 2000, gain: 0 }),
            peqBand({ frequency: 99999, type: 'hs', gain: 3 })
        ]
    },
    {
        // 0のsampleRateは48000に倒れる（Number(x) || 48000）。帯が全部効かない（gain 0のpeakingだけ）。
        name: 'min-flat-rate0',
        sampleRate: 0, taps: 8192, phase: 'min',
        bands: [100, 316, 1000, 3160, 10000].map(frequency => peqBand({ frequency }))
    },
    {
        // 8000未満は8000へ。中心の上限は0.49·8000=3920Hz。
        name: 'lin-low-rate',
        sampleRate: 5000.4, taps: 8192, phase: 'lin',
        bands: [
            peqBand({ frequency: 100, gain: 3 }),
            peqBand({ frequency: 3919, gain: -3 }),
            peqBand({ frequency: 5000, type: 'lp', slope: 12, q: 0.7 }),
            peqBand({ frequency: 1000, type: 'bp', q: 0.2 }),
            peqBand({ frequency: 2000, type: 'no', enabled: false })
        ]
    }
];

const responseStride = 8;
const peqDesigns = peqCases.map(input => {
    const candidate = () => ({
        sampleRate: input.sampleRate,
        taps: input.taps,
        phase: input.phase,
        eqBands: input.bands.map(band => ({ ...band }))
    });
    const result = peq.designFiveBandFirPeq(candidate());
    const indices = Array.from({ length: Math.ceil(result.response.frequencies.length / responseStride) },
        (_, k) => k * responseStride);
    return {
        input,
        config: result.config,
        filterDelaySamples: result.latencyInfo.filterDelaySamples,
        resolutionHz: result.latencyInfo.resolutionHz,
        qualityWarnings: result.qualityWarnings,
        maximumErrorDb: probePeqMaximumErrorDb(candidate(), result),
        responsePointCount: result.response.frequencies.length,
        response: {
            indices,
            frequencies: indices.map(i => result.response.frequencies[i]),
            targetDb: indices.map(i => finite(result.response.targetDb[i], 'targetDb')),
            realizedDb: indices.map(i => finite(result.response.realizedDb[i], 'realizedDb'))
        },
        channel: channelStats(result.channels[0])
    };
});

// ---- FIR Crossover ----

const lowWeight = [];
for (const [cutoff, slope] of [[2000, 24], [80, 384], [12000, 48], [300, 96]]) {
    for (const frequency of [0, -5, 1e-9, 1, 10, 79, 80, 81, 300, 1999, 2000, 2001, 11000, 24000, 1e7]) {
        lowWeight.push({ frequency, cutoff, slope,
            weight: crossover.crossoverLowWeight(frequency, cutoff, slope) });
    }
}

// normalizeConfigは書き出されていないので、designFIRCrossoverが返すconfigから取る。
// NaNはJSONに書けないので、Swiftへはnull（=NaN）で渡す。
const nanToNull = values => values.map(v => (Number.isNaN(v) ? null : v));
const normalizeInputs = [
    { sampleRate: 48000, taps: 8192, phase: 'min', bandCount: 2, frequencies: [2000, 4000, 8000], slopes: [-24, -24, -24] },
    { sampleRate: 44100.4, taps: 8192, phase: 'lin', bandCount: 3, frequencies: [300, 250, 9000], slopes: [48, -96, 30] },
    { sampleRate: 0, taps: 1234, phase: 'min', bandCount: 7, frequencies: [NaN, 5, 30000], slopes: [-384, -288, -192] },
    { sampleRate: 1000, taps: 8192, phase: 'lin', bandCount: 4, frequencies: [470, 480, 490], slopes: [72, 144, 24] },
    { sampleRate: 1000000, taps: 131072, phase: 'min', bandCount: 4, frequencies: [100, 200000, 500000], slopes: [-24, -48, -72] },
    { sampleRate: NaN, taps: 16384, phase: 'min', bandCount: 0, frequencies: [], slopes: [] },
    { sampleRate: 96000, taps: 65536, phase: 'lin', bandCount: 1, frequencies: [1, 2], slopes: [-23, -25] },
    { sampleRate: 22050.5, taps: 32768, phase: 'min', bandCount: 3, frequencies: [10583, 10584, 10585], slopes: [-48, -48, -48] },
    { sampleRate: -44100, taps: 8192, phase: 'min', bandCount: 3, frequencies: [100, 1000, 3000], slopes: [96, 96, 96] }
];
const firNormalize = normalizeInputs.map(input => {
    const result = crossover.designFIRCrossover({ ...input });
    return {
        input: { ...input, sampleRate: Number.isNaN(input.sampleRate) ? null : input.sampleRate,
            frequencies: nanToNull(input.frequencies) },
        config: result.config
    };
});

const bandMagnitudeConfigs = [
    { sampleRate: 48000, taps: 8192, phase: 'min', bandCount: 2, frequencies: [2000, 4000, 8000], slopes: [24, 24, 24] },
    { sampleRate: 48000, taps: 8192, phase: 'lin', bandCount: 3, frequencies: [250, 2500, 8000], slopes: [48, 384, 24] },
    { sampleRate: 96000, taps: 8192, phase: 'min', bandCount: 4, frequencies: [80, 800, 8000], slopes: [96, 144, 288] }
];
const bandProbeFrequencies = [0, 1, 20, 80, 100, 250, 800, 1000, 2000, 2500, 4000, 8000, 16000, 24000, 46000];
const firBandMagnitudes = bandMagnitudeConfigs.map(config => ({
    config,
    frequencies: bandProbeFrequencies,
    magnitudes: bandProbeFrequencies.map(f => plain(crossover.crossoverBandMagnitudes(config, f)))
}));

// design-worker.js:24-27と同じ経路で、上流のbuildIrAssetPayloadに組ませる。
function crossoverPayloadHead(result) {
    const paths = result.channels.flatMap((_, band) => [
        { inputSlot: 0, outputSlot: band * 2, irChannel: band },
        { inputSlot: 1, outputSlot: band * 2 + 1, irChannel: band }
    ]);
    const payload = new Uint8Array(assetPayload.buildIrAssetPayload({
        channels: result.channels,
        sampleRate: result.config.sampleRate,
        topology: assetPayload.IR_ASSET_TOPOLOGY.matrix,
        paths
    }));
    return { paths, payloadBytes: payload.length, payloadHead: plain(payload.slice(0, 32 + paths.length * 12)) };
}

const crossoverDesignInputs = [
    { name: 'min-2band-48k', sampleRate: 48000, taps: 8192, phase: 'min', bandCount: 2, frequencies: [2000, 4000, 8000], slopes: [-24, -24, -24] },
    { name: 'lin-3band-48k', sampleRate: 48000, taps: 8192, phase: 'lin', bandCount: 3, frequencies: [300, 3000, 8000], slopes: [-48, -96, -24] },
    { name: 'min-4band-44k1', sampleRate: 44100, taps: 8192, phase: 'min', bandCount: 4, frequencies: [120, 1200, 9000], slopes: [-192, -384, -72] },
    { name: 'lin-4band-96k', sampleRate: 96000, taps: 16384, phase: 'lin', bandCount: 4, frequencies: [80, 800, 8000], slopes: [-24, -144, -288] },
    { name: 'lin-2band-top', sampleRate: 48000, taps: 8192, phase: 'lin', bandCount: 2, frequencies: [23000, 4000, 8000], slopes: [-384, -24, -24] }
];
const firDesigns = crossoverDesignInputs.map(input => {
    const { name, ...candidate } = input;
    const result = crossover.designFIRCrossover(candidate);
    return {
        input,
        config: result.config,
        latencyInfo: result.latencyInfo,
        channels: result.channels.map(channelStats),
        ...crossoverPayloadHead(result)
    };
});

// analyzeFIRAtFrequencies: 決まった乱数の短いFIR。bin上・binの間・0・Nyquistより上。
const analyzeRandom = lcg(7);
const analyzeImpulse = Float32Array.from({ length: 64 }, (_, i) =>
    (analyzeRandom() * 2 - 1) * Math.exp(-i / 12));
const analyzeFrequencies = [0, 1, 750, 1000, 1234.5, 12000, 23999.9, 24000, 30000, -10];
const firAnalyze = [{
    impulse: plain(analyzeImpulse),
    sampleRate: 48000,
    frequencies: analyzeFrequencies,
    response: plain(crossover.analyzeFIRAtFrequencies(analyzeImpulse, 48000, analyzeFrequencies))
}];

// ---- Bass Management: 画面のクラスの判断 ----

class PluginBase {
    constructor(name, description) {
        this.name = name;
        this.description = description;
        this.enabled = true;
    }
    registerProcessor() {}
    _setValidatedParameters() {}
    updateParameters() {}
    parseFiniteNumber(value, minimum, maximum, previous) {
        const number = Number(value);
        return Number.isFinite(number) ? Math.max(minimum, Math.min(maximum, number)) : previous;
    }
    ensureDspTelemetrySubscription() {}
    disposeDspTelemetrySubscription() {}
    clearWasmAsset() {}
    setWasmAsset() { return 0; }
    getParameters() { return {}; }
    cleanup() {}
}
const pluginSource = fs.readFileSync(path.join(root, 'plugins', 'basics', 'bass_management.js'), 'utf8');
const BassManagementPlugin = new Function('PluginBase', 'window', 'document',
    `${pluginSource}\nreturn BassManagementPlugin;`)(PluginBase, {}, undefined);

function plugin({ roles, routes, inversions, subs, width, lfeLowpass = false }) {
    const p = new BassManagementPlugin();
    p.channel = 'A';
    p.ro = [...roles];
    p.rt = [...routes];
    p.ri = [...inversions];
    p.su = subs;
    p.lo = lfeLowpass;
    p._processingChannelCount = width;
    return p;
}

const zeros16 = () => Array(16).fill(0);
function state(width, edit) {
    const s = { roles: zeros16(), routes: zeros16(), inversions: zeros16(), subs: 0, width };
    edit(s);
    return s;
}

// 8つの誤りと誤りなしを、幅1・2・16（と0・17・その間）で1つずつ作る。
const structured = [
    state(0, () => {}),
    state(17, () => {}),
    state(1, s => { s.subs = 0b10; }),                                  // Subが幅の外
    state(2, s => { s.subs = 0b100; }),
    state(1, s => { s.roles[1] = 1; }),                                 // 幅の外のManaged
    state(2, s => { s.roles[5] = 2; }),                                 // 幅の外のLFE
    state(2, s => { s.routes[9] = 4; }),                                // 幅の外の経路
    state(1, s => { s.subs = 1; }),                                     // Full RangeがSub
    state(2, s => { s.subs = 2; s.roles[1] = 1; s.roles[0] = 2; }),     // ManagedがSub
    state(16, s => { s.subs = 1 << 15; s.roles.fill(3); s.roles[15] = 0; }),
    state(1, s => { s.subs = 1; s.roles[0] = 2; s.inversions[0] = 1; }),  // 入っていない経路を反転
    state(2, s => { s.subs = 2; s.roles[0] = 1; s.roles[1] = 2; s.routes[0] = 2; s.inversions[0] = 3; s.routes[1] = 2; }),
    state(16, s => { s.subs = 1 << 3; s.roles.fill(3); s.roles[3] = 2; s.roles[0] = 1; s.routes[0] = 8; s.inversions[0] = 1 << 14; }),
    state(1, s => { s.subs = 1; s.roles[0] = 2; }),                     // 送り先が無い
    state(2, s => { s.subs = 2; s.roles[0] = 1; s.roles[1] = 2; s.routes[1] = 2; }),
    state(16, s => { s.subs = 1 << 3; s.roles.fill(3); s.roles[3] = 2; s.roles[7] = 1; s.routes[3] = 8; }),
    state(1, s => { s.subs = 1; s.roles[0] = 2; s.routes[0] = 2; }),    // Subでない出口へ
    state(2, s => { s.subs = 2; s.roles[0] = 1; s.roles[1] = 2; s.routes[0] = 1; s.routes[1] = 2; }),
    state(16, s => { s.subs = 1 << 3; s.roles.fill(3); s.roles[3] = 2; s.roles[0] = 1; s.routes[3] = 8; s.routes[0] = 8 | (1 << 15); }),
    state(1, () => {}),                                                  // 誤りなし（Subなし）
    state(2, s => { s.subs = 2; s.roles[0] = 1; s.roles[1] = 2; s.routes[0] = 2; s.routes[1] = 2; s.inversions[0] = 2; }),
    state(16, s => {                                                     // 誤りなし（7.1＋Sub 2本）
        s.subs = (1 << 3) | (1 << 9);
        for (let ch = 0; ch < 16; ch += 1) s.roles[ch] = ch < 8 ? 1 : 3;
        s.roles[3] = 2; s.roles[9] = 2;
        for (const ch of [0, 1, 2, 4, 5, 6, 7]) s.routes[ch] = (1 << 3) | (1 << 9);
        s.routes[3] = 1 << 3; s.routes[9] = 1 << 9;
        s.inversions[5] = 1 << 9;
    })
];
const random = lcg(20260927);
const pick = list => list[Math.floor(random() * list.length)];
const randomStates = Array.from({ length: 90 }, () => {
    const width = pick([1, 2, 3, 4, 6, 8, 12, 16]);
    return state(width, s => {
        const reach = Math.min(16, width + (random() < 0.2 ? 2 : 0));
        for (let ch = 0; ch < reach; ch += 1) s.roles[ch] = pick([0, 1, 1, 2, 3, 3]);
        for (let ch = 0; ch < 16; ch += 1) if (ch >= reach) s.roles[ch] = pick([0, 0, 3]);
        const sub = Math.floor(random() * width);
        s.subs = 1 << sub;
        if (random() < 0.3) s.subs |= 1 << Math.floor(random() * width);
        if (random() < 0.08) s.subs |= 1 << Math.min(15, width + Math.floor(random() * 3));
        if (random() < 0.7) s.roles[sub] = 2;
        for (let ch = 0; ch < width; ch += 1) {
            if (s.roles[ch] !== 1 && s.roles[ch] !== 2) continue;
            const roll = random();
            s.routes[ch] = roll < 0.1 ? 0 : roll < 0.2 ? (1 << Math.floor(random() * 16)) : s.subs;
            s.inversions[ch] = random() < 0.2 ? (1 << Math.floor(random() * 16)) & (random() < 0.5 ? s.routes[ch] : 0xffff) : 0;
        }
    });
});

const configurationError = [...structured, ...randomStates].map(s => ({
    ...s,
    message: plugin(s)._configurationError(s.width)
}));

const routeSummary = [...structured.slice(2), ...randomStates.slice(0, 30),
    state(4, s => { s.subs = 8; s.roles = [0, 0, 3, 2, ...Array(12).fill(0)]; }),  // Sub（Ch 4）に置いたLFEが経路なし（Unusedも混ぜる）
    state(3, s => { s.roles[0] = 1; })                                          // Subなし
].filter(s => s.width >= 1 && s.width <= 16).map(s => {
    const p = plugin(s);
    p._routeElement = { textContent: '' };
    p._errorElement = null;
    p._renderConfiguration();
    return { roles: s.roles, routes: s.routes, subs: s.subs, width: s.width, text: p._routeElement.textContent };
});

const subOutput = [];
for (const [index, s] of [structured[21], structured[20], structured[14], randomStates[3], randomStates[11]].entries()) {
    for (const channel of [0, 3, 9, 15]) {
        for (const enabled of [true, false]) {
            if (channel >= 16) continue;
            const p = plugin(s);
            let captured = null;
            p.setParameters = params => { captured = params; };
            p._setSubOutputEnabled(channel, enabled);
            subOutput.push({
                case: index,
                before: { roles: s.roles, routes: s.routes, inversions: s.inversions, subs: s.subs },
                width: s.width,
                channel,
                enabled,
                after: {
                    roles: captured.ro ?? s.roles,
                    routes: captured.rt,
                    inversions: captured.ri,
                    subs: captured.su
                }
            });
        }
    }
}

const linearInputs = [];
for (const s of [...structured.slice(2), ...randomStates.slice(0, 40)]) {
    for (const lfeLowpass of [false, true]) {
        linearInputs.push({ roles: s.roles, lfeLowpass, width: s.width,
            inputs: plugin({ ...s, lfeLowpass })._linearInputChannels(s.width) });
    }
}

const designRates = [48000, 44100, 44100.4, 44100.5, 47999.5, 7999, 7999.6, 8000.5, 800000, 768000.4, 96000.49, -5, 0]
    .map(sampleRate => ({ sampleRate,
        normalized: bass.normalizeBassManagementDesignConfig({ sampleRate }).sampleRate }));

// ---- Bass Management: 設計 ----

const bassTaps = [8192, 16384, 32768];
const bassDesignInputs = [
    {
        name: '5.1-shared-48k',
        sampleRate: 48000, width: 6, tapsIndex: 0,
        roles: [1, 1, 1, 2, 1, 1], frequencies: [80, 80, 80, 80, 80, 80], slopes: [24, 24, 24, 24, 24, 24],
        lfeLowpass: false, lfeFrequency: 120, lfeSlope: 24
    },
    {
        name: '4ch-mixed-44k1',
        sampleRate: 44100, width: 4, tapsIndex: 0,
        roles: [1, 1, 2, 1], frequencies: [80, 100, 80, 85.5], slopes: [24, 48, 24, 96],
        lfeLowpass: true, lfeFrequency: 120, lfeSlope: 48
    },
    {
        name: '2ch-clamped-96k',
        sampleRate: 96000, width: 2, tapsIndex: 1,
        roles: [1, 2], frequencies: [19, 80], slopes: [48, 24],
        lfeLowpass: true, lfeFrequency: 300.7, lfeSlope: 96
    }
];
const bassDesigns = bassDesignInputs.map(input => {
    const pad = (values, fill) => [...values, ...Array(16 - values.length).fill(fill)];
    const result = bass.designBassManagement({
        sampleRate: input.sampleRate,
        channelCount: input.width,
        taps: bassTaps[input.tapsIndex],
        roles: pad(input.roles, 0),
        frequencies: pad(input.frequencies, 80),
        slopes: pad(input.slopes, 24),
        lfeLowpass: input.lfeLowpass,
        lfeFrequency: input.lfeFrequency,
        lfeSlope: input.lfeSlope
    });
    // design-worker.js:34-44と同じ経路で組む。
    const paths = result.inputChannels.map((inputSlot, irChannel) => ({ inputSlot, outputSlot: inputSlot, irChannel }));
    const payload = new Uint8Array(assetPayload.buildIrAssetPayload({
        channels: result.channels,
        sampleRate: result.config.sampleRate,
        topology: assetPayload.IR_ASSET_TOPOLOGY.matrix,
        paths
    }));
    return {
        input,
        sampleRate: result.config.sampleRate,
        taps: result.config.taps,
        inputChannels: result.inputChannels,
        responseFrequencies: result.responseFrequencies,
        responses: result.responses.map(plain),
        l1Norms: result.l1Norms,
        latencyInfo: result.latencyInfo,
        payloadBytes: payload.length,
        payloadHead: plain(payload.slice(0, 32 + paths.length * 12)),
        channels: result.channels.map(channelStats)
    };
});

// ---- 書く ----

const golden = sortKeys({
    about: 'Tools/golden/designers_a_golden.mjs が上流（EFFETUNE_ROOT）に作らせた見本。手で直さない。'
        + 'FFTだけDoubleの基数2に差し替えてある（上流のset*FftBackend）。',
    bandFirPeq: { magnitude: peqMagnitude, designs: peqDesigns },
    firCrossover: {
        lowWeight,
        normalize: firNormalize,
        bandMagnitudes: firBandMagnitudes,
        designs: firDesigns,
        analyze: firAnalyze
    },
    bassManagement: {
        configurationError,
        routeSummary,
        subOutput,
        linearInputs,
        designRates,
        designs: bassDesigns
    }
});

// 数の並びは1行に、入れ物は字下げして書く（差分が読める大きさに収める）。
function render(value, indent = '') {
    const inner = indent + ' ';
    if (Array.isArray(value)) {
        if (value.every(item => item === null || typeof item !== 'object')) {
            return '[' + value.map(item => JSON.stringify(item)).join(', ') + ']';
        }
        return '[\n' + value.map(item => inner + render(item, inner)).join(',\n') + '\n' + indent + ']';
    }
    if (value && typeof value === 'object') {
        const keys = Object.keys(value);
        if (keys.length === 0) return '{}';
        return '{\n' + keys.map(key => inner + JSON.stringify(key) + ': ' + render(value[key], inner))
            .join(',\n') + '\n' + indent + '}';
    }
    return JSON.stringify(value);
}

fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, render(golden) + '\n');
const kinds = new Set(configurationError.map(c => c.message.replace(/\d+/g, '#')));
console.log(`wrote ${path.relative(repo, outFile)} (${fs.statSync(outFile).size} bytes); `
    + `configurationError kinds: ${kinds.size}`);
