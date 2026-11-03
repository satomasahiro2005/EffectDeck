// Tools/golden/fir_golden.mjs
// FIR設計の共通の道具（DSP/FIRDesign.swift）の見本を、上流のJSそのものに作らせる。
// Swift側はTests/Unit/FIRDesignTests.swiftが同じ入力をFIRDesignに通して照合する。
//
//   root=$(bash Tools/golden/extract_pin.sh)
//   EFFETUNE_ROOT="$root" node Tools/golden/fir_golden.mjs
//
// 読むもの（書き出されていない関数は、モジュールの文面の末尾にexportを1行足してdata: URLで読む。
// 上流のファイルには書かない）:
//   js/utils/measurement-dsp/resample.js   resampleWindowedSinc、besselI0
//   js/fir-crossover/design-core.js        minimumPhaseForMagnitude、createWindow
//   js/five-band-fir-peq/design-core.js    minimumPhaseForMagnitude、createWindow、sampleAtFrequency
//   js/room-eq/design-core.js              minimumPhaseForMagnitude
//   js/group-delay-eq/design-core.js       designGroupDelayFilter、groupDelayResponseFrequencies、sampleAtFrequency
// 写しが複数ある関数は、全部が同じ答えを出すことをここで確かめてから1つを書く（違えば止まる）。
//
// **FFTは上流の既定のもの（js/utils/measurement-dsp/fft.js）を使う。**あちらは回転因子の表が
// Float32Arrayなので、doubleのvDSPで回すSwiftとは1e-7ほどの差が出る。照合の許容はその分を見込む。
//
// 出力はTests/Fixtures/FIR/fir-golden.json。キーは並べ替えて書き、入力は決まった乱数で作るので、
// 同じ上流からは同じバイトが出る（CIのgeneratedジョブが作り直して差分を見る）。
// 長い数の並びはfloat64（係数の入出力はfloat32）のリトルエンディアンをbase64にして入れる。

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.join(here, '..', '..');
const root = path.resolve(process.env.EFFETUNE_ROOT || path.join(repo, 'Vendor', 'effetune'));
const outFile = path.join(repo, 'Tests', 'Fixtures', 'FIR', 'fir-golden.json');

const files = {
    resample: path.join(root, 'js', 'utils', 'measurement-dsp', 'resample.js'),
    fft: path.join(root, 'js', 'utils', 'measurement-dsp', 'fft.js'),
    crossover: path.join(root, 'js', 'fir-crossover', 'design-core.js'),
    peq: path.join(root, 'js', 'five-band-fir-peq', 'design-core.js'),
    roomEq: path.join(root, 'js', 'room-eq', 'design-core.js'),
    groupDelay: path.join(root, 'js', 'group-delay-eq', 'design-core.js')
};

async function importWithPrivates(file, names) {
    let source = fs.readFileSync(file, 'utf8');
    source = source.replace(/(\bfrom\s+|\bimport\s+)(['"])(\.{1,2}\/[^'"]+)\2/g,
        (match, head, quote, specifier) => head + quote + new URL(specifier, pathToFileURL(file)).href + quote);
    source += '\nexport { ' + names.map(name => `${name} as __${name}`).join(', ') + ' };\n';
    return import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
}

const resample = await importWithPrivates(files.resample, ['besselI0']);
const crossover = await importWithPrivates(files.crossover, ['minimumPhaseForMagnitude', 'createWindow']);
const peq = await importWithPrivates(files.peq, ['minimumPhaseForMagnitude', 'createWindow', 'sampleAtFrequency']);
const roomEq = await importWithPrivates(files.roomEq, ['minimumPhaseForMagnitude']);
const groupDelay = await importWithPrivates(files.groupDelay, ['sampleAtFrequency']);

// ---- 道具 ----

function lcg(seed) {
    let state = seed >>> 0;
    return () => {
        state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
        return state / 4294967296 * 2 - 1;
    };
}

function f64(values) {
    const bytes = Buffer.alloc(values.length * 8);
    for (let i = 0; i < values.length; i += 1) bytes.writeDoubleLE(values[i], i * 8);
    return bytes.toString('base64');
}

function f32(values) {
    const bytes = Buffer.alloc(values.length * 4);
    for (let i = 0; i < values.length; i += 1) bytes.writeFloatLE(values[i], i * 4);
    return bytes.toString('base64');
}

function sameArrays(label, arrays) {
    const [first, ...rest] = arrays.map(a => Array.from(a));
    for (const other of rest) {
        if (other.length !== first.length || other.some((v, i) => !Object.is(v, first[i]))) {
            throw new Error(`${label}: 上流の写しどうしで答えが違う`);
        }
    }
    return first;
}

// ---- besselI0（resample.js:5-14） ----

const besselArguments = [0, 1e-3, 0.5, 1, 2, 5, 8.96, 10.0548, 20, 35, 50];
const bessel = besselArguments.map(x => [x, resample.__besselI0(x)]);

// ---- createWindow（fir-crossover・five-band-fir-peq） ----

const windows = [];
for (const taps of [1, 2, 3, 9, 10, 11, 19, 20, 21, 100, 101, 1000]) {
    for (const phase of ['min', 'lin']) {
        const values = sameArrays(`createWindow ${taps} ${phase}`,
            [crossover.__createWindow(taps, phase), peq.__createWindow(taps, phase)]);
        windows.push({ minimumPhase: phase === 'min', taps, window: f64(values) });
    }
}

// ---- minimumPhaseForMagnitude（3本） ----

function magnitudes(kind, fftSize, seed) {
    const bins = fftSize / 2 + 1;
    const random = lcg(seed);
    const out = new Float64Array(bins);
    for (let bin = 0; bin < bins; bin += 1) {
        const x = bin / (bins - 1);
        if (kind === 'random') out[bin] = 0.05 + Math.abs(random()) * 2;
        else if (kind === 'lowpass') out[bin] = 1 / Math.sqrt(1 + (x / 0.2) ** 8);
        else if (kind === 'peak') out[bin] = 1 + 3 * Math.exp(-(((x - 0.3) / 0.03) ** 2));
        else if (kind === 'floored') out[bin] = bin % 5 === 0 ? 0 : (bin % 7 === 0 ? 1e-12 : 0.5 + x);
        else if (kind === 'flat') out[bin] = 1;
    }
    return out;
}

const minimumPhase = [];
for (const [kind, fftSize, seed] of [['random', 4, 1], ['random', 16, 2], ['lowpass', 256, 3], ['peak', 1024, 4],
    ['floored', 512, 5], ['flat', 64, 6], ['lowpass', 8192, 7]]) {
    const input = magnitudes(kind, fftSize, seed);
    const phase = sameArrays(`minimumPhase ${kind} ${fftSize}`, [
        crossover.__minimumPhaseForMagnitude(input, fftSize),
        peq.__minimumPhaseForMagnitude(input, fftSize),
        roomEq.__minimumPhaseForMagnitude(input, fftSize)
    ]);
    minimumPhase.push({ fftSize, magnitudes: f64(input), name: `${kind}_${fftSize}`, phase: f64(phase) });
}

// ---- resampleWindowedSinc ----

function signal(kind, frames, seed, rate) {
    const random = lcg(seed);
    const out = new Float32Array(frames);
    for (let i = 0; i < frames; i += 1) {
        if (kind === 'impulse') out[i] = i === Math.floor(frames / 3) ? 1 : 0;
        else if (kind === 'noise') out[i] = random();
        else if (kind === 'sine') out[i] = Math.sin(2 * Math.PI * 1000 * i / rate) * 0.5;
        else if (kind === 'decay') out[i] = random() * Math.exp(-i / (frames / 6));
    }
    return out;
}

const resampleCases = [
    ['noise', 400, 11, 44100, 48000, undefined],
    ['noise', 400, 12, 48000, 44100, undefined],
    ['sine', 900, 13, 96000, 48000, undefined],
    ['impulse', 300, 14, 48000, 96000, undefined],
    ['decay', 700, 15, 22050, 48000, undefined],
    ['noise', 250, 16, 48000, 192000, undefined],
    ['decay', 3000, 17, 192000, 44100, undefined],
    ['impulse', 100, 18, 8000, 48000, undefined],
    ['noise', 60, 19, 44100, 48000, undefined],
    ['noise', 1, 20, 48000, 44100, undefined],
    // crosstalk-cancellationが渡す形（radiusを明示）。
    ['decay', 600, 21, 44100, 48000, { radius: 24 }],
    ['decay', 600, 22, 96000, 48000, { radius: 40 }]
];
const resampled = resampleCases.map(([kind, frames, seed, sourceRate, targetRate, options]) => {
    const input = signal(kind, frames, seed, sourceRate);
    const output = resample.resampleWindowedSinc(input, sourceRate, targetRate, options);
    return {
        input: f32(input),
        name: `${kind}_${frames}_${sourceRate}_${targetRate}${options ? '_r' + options.radius : ''}`,
        output: f32(output),
        radius: options?.radius ?? null,
        sourceRate,
        targetRate
    };
});

// ---- sampleAtFrequency（five-band-fir-peq・group-delay-eq） ----

const sampleValues = Array.from({ length: 17 }, (_, i) => Math.sin(i * 0.7) * 10 + i);
const sampleQueries = [0, 1, 1234.5, 3000, 11999.9, 12000, 23999, 24000, 24000.5, 30000, 1e9];
const samples = sampleQueries.map(frequency => {
    const [value] = sameArrays(`sampleAtFrequency ${frequency}`, [
        [peq.__sampleAtFrequency(sampleValues, frequency, 32, 48000)],
        [groupDelay.__sampleAtFrequency(sampleValues, frequency, 32, 48000)]
    ]);
    return [frequency, value];
});

// ---- measureResponse（group-delay-eqの設計の結果から） ----

const groupDelayModule = await import(pathToFileURL(files.groupDelay).href);
const measureCases = [
    ['gdeq_4096_48000', [0, 0, 0.5, 1, 2, 3, 2, 1, 0.5, 0, 0, -0.5, -1, 0, 0], 4096, 48000],
    ['gdeq_8192_96000', [4, 3, 2, 1, 0, -1, -2, -1, 0, 0.25, 0.5, 0.25, 0, 0, 0], 8192, 96000]
];
const measure = measureCases.map(([name, delaysMs, taps, sampleRate]) => {
    const design = groupDelayModule.designGroupDelayFilter({ delaysMs, taps, sampleRate });
    return {
        bulkDelaySamples: design.bulkDelaySamples,
        frequencies: f64(groupDelayModule.groupDelayResponseFrequencies(sampleRate)),
        ir: f32(design.ir),
        name,
        realizedMs: f64(design.response.realizedMs),
        rippleDb: design.rippleDb,
        sampleRate,
        size: taps * 2
    };
});

// ---- TypedArray.fill(0, start)（zeroTailの約束） ----

const fillSource = Array.from({ length: 8 }, (_, i) => i + 1);
const zeroTail = [-20, -8, -3, -1, 0, 3, 7, 8, 12].map(start => {
    const values = Float64Array.from(fillSource);
    values.fill(0, start);
    return [start, Array.from(values)];
});

// ---- Math.round（jsRoundの約束） ----
// JSONに-0は書けないので、入力と答えが-0だったかは別に持つ（[入力, 答え, 入力が-0, 答えが-0]）。

const roundInputs = [0, -0, 0.5, -0.5, 1.5, -1.5, 2.5, -2.5, 0.49999999999999994, -0.49999999999999994,
    0.2, -0.2, -0.7, 1e-17, -1e-17, 4503599627370495.5, 4503599627370497, -4503599627370497,
    9007199254740993, 123456.5, -123456.5, 1.7976931348623157e308, -1.7976931348623157e308,
    5e-324, -5e-324, 0.5000000000000001, -0.5000000000000001];
const round = roundInputs.map(x => {
    const r = Math.round(x);
    return [x, r, Object.is(x, -0), Object.is(r, -0)];
});

// ---- 書き出し ----

function sha256(file) {
    const text = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
    return crypto.createHash('sha256').update(text).digest('hex');
}

const out = {
    bessel,
    generator: 'Tools/golden/fir_golden.mjs',
    jsRound: round,
    measureResponse: measure,
    minimumPhase,
    resample: resampled,
    sampleAtFrequency: { fftSize: 32, queries: samples, sampleRate: 48000, values: sampleValues },
    upstream: Object.fromEntries(Object.values(files).map(file =>
        [path.relative(root, file).split(path.sep).join('/'), sha256(file)])),
    windows,
    zeroTail: { source: fillSource, starts: zeroTail }
};

function sortKeys(value) {
    if (Array.isArray(value)) return value.map(sortKeys);
    if (value && typeof value === 'object') {
        return Object.fromEntries(Object.keys(value).sort().map(key => [key, sortKeys(value[key])]));
    }
    return value;
}

function write(value, indent = '') {
    if (Array.isArray(value)) {
        if (value.every(item => !item || typeof item !== 'object')) return JSON.stringify(value);
        const inner = indent + ' ';
        return '[\n' + value.map(item => inner + JSON.stringify(item)).join(',\n') + '\n' + indent + ']';
    }
    if (value && typeof value === 'object') {
        const inner = indent + ' ';
        const entries = Object.entries(value).map(([key, item]) => inner + JSON.stringify(key) + ': ' + write(item, inner));
        return '{\n' + entries.join(',\n') + '\n' + indent + '}';
    }
    return JSON.stringify(value);
}

fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, write(sortKeys(out)) + '\n');
console.log(`wrote ${path.relative(repo, outFile)} (${minimumPhase.length} minimumPhase, ${resampled.length} resample, `
    + `${windows.length} windows, ${measure.length} measureResponse, ${fs.statSync(outFile).size} bytes)`);
