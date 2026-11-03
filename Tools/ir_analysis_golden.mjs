// ir_analysis_golden.mjs
// IR ReverbのEDCグラフの数字（ETIRAnalysis.analyze）の見本を、上流のprepareIrとemitPreparedIrそのものに作らせる。
//
// 図が描くのは2本。Current = emitPreparedIrが返すanalysis（送った面の解析）、
// Original = prepareIrのanalysis.original（decay・trim・最後の利得の前の全部の面の解析）。
// 呼び方はir_reverb.jsの_prepareHostPcm（:533-548）と_createPreparedAsset（:550-570）と同じ
// （analysisPointsは両方1600、prepareのmaxFramesは面の長さ）。
// Swift側はETIRPreparation.prepare → selectChannels → truncateを通した面を解析して照合する
// （Tests/Unit/IRAnalysisTests.swift）。
//
//   root=$(bash Tools/golden/extract_pin.sh)
//   EFFETUNE_ROOT="$root" node Tools/ir_analysis_golden.mjs
//
// 上流の木は EFFETUNE_ROOT（ir_prepare_golden.mjs と同じ）。無ければ Vendor/effetune を読む。
// 入力は大きいので（8kHzで3秒のステレオ）、このファイルに自分の分を持つ（prepare-golden.jsonとは共有しない）。
// 面と解析の配列はfloat32のリトルエンディアンをbase64で入れる。

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const effetune = path.resolve(process.env.EFFETUNE_ROOT || path.join(root, 'Vendor', 'effetune'));
const preparationFile = path.join(effetune, 'js', 'ir-library', 'ir-preparation.js');
const onsetFile = path.join(effetune, 'js', 'utils', 'measurement-dsp', 'onset.js');
const outFile = path.join(root, 'Tests', 'Fixtures', 'IR', 'analysis-golden.json');

const { prepareIr, emitPreparedIr } = await import(pathToFileURL(preparationFile).href);

// ---- 入力（ir_prepare_golden.mjsと同じ作り方） ----

function lcg(seed) {
    let state = seed >>> 0;
    return () => {
        state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
        return state / 4294967296 * 2 - 1;
    };
}

function decayingIr({ frames, lead = 0, direct = 0.9, amplitude = 0.4, decay = 150, seed = 1, gap = 0 }) {
    const random = lcg(seed);
    const out = new Float32Array(frames);
    if (lead < frames) out[lead] = direct;
    for (let i = lead + 1 + gap; i < frames; i += 1) {
        out[i] = amplitude * random() * Math.exp(-(i - lead) / decay);
    }
    return out;
}

const zeros = frames => new Float32Array(frames);

const inputs = {
    // 8kHzで3秒。エネルギーが-60dB落ちるのが約0.8秒（振幅がexp(-t/926フレーム)）。
    room24000: [
        decayingIr({ frames: 24000, lead: 40, seed: 101, decay: 926, amplitude: 0.5 }),
        decayingIr({ frames: 24000, lead: 44, seed: 102, decay: 926, amplitude: 0.35, direct: 0.6 })
    ],
    stereo800: [
        decayingIr({ frames: 800, lead: 20, seed: 21, direct: 0.8 }),
        decayingIr({ frames: 800, lead: 20, seed: 22, direct: 0.5, amplitude: 0.25 })
    ],
    quad600: [
        decayingIr({ frames: 600, lead: 12, seed: 31, direct: 0.9 }),
        decayingIr({ frames: 600, lead: 12, seed: 32, direct: 0.3, amplitude: 0.15 }),
        decayingIr({ frames: 600, lead: 14, seed: 33, direct: 0.25, amplitude: 0.12 }),
        decayingIr({ frames: 600, lead: 13, seed: 34, direct: 0.7, amplitude: 0.35 })
    ],
    mono4000: [decayingIr({ frames: 4000, lead: 5, seed: 41, decay: 900 })],
    mono100zero: [zeros(100)],
    mono40: [decayingIr({ frames: 40, lead: 3, seed: 71, decay: 10 })],
    triple500: [
        decayingIr({ frames: 500, lead: 6, seed: 91 }),
        decayingIr({ frames: 500, lead: 7, seed: 92, direct: 0.4 }),
        decayingIr({ frames: 500, lead: 8, seed: 93, direct: 0.2, amplitude: 0.1 })
    ]
};

// ---- 見本 ----

const defaults = { directCut: true, cutOffsetMs: 0, decayPercent: 100, trimPercent: 100 };
const TOPOLOGY = { mono: 1, independent: 2, trueStereo: 3, matrix: 4 };

// [name, input, sampleRate, topology, options, emitMaxFrames（nullなら準備後の長さ）]
const cases = [
    ['a_room_indep_dc_trunc20000', 'room24000', 8000, TOPOLOGY.independent, {}, 20000],
    ['b_room_indep_nodc_trunc20000', 'room24000', 8000, TOPOLOGY.independent, { directCut: false }, 20000],
    ['c_ts_dt200_tr60', 'quad600', 48000, TOPOLOGY.trueStereo, { decayPercent: 200, trimPercent: 60 }, null],
    ['d_ts_dt50_tr60_dc', 'quad600', 48000, TOPOLOGY.trueStereo, { decayPercent: 50, trimPercent: 60 }, null],
    ['e_stereo_as_mono', 'stereo800', 48000, TOPOLOGY.mono, {}, null],
    ['f_matrix_dt200_nodc', 'triple500', 48000, TOPOLOGY.matrix, { directCut: false, decayPercent: 200 }, null],
    ['g_zero', 'mono100zero', 48000, TOPOLOGY.mono, {}, null],
    ['h_short40', 'mono40', 48000, TOPOLOGY.mono, {}, null],
    ['i_long_tr60', 'mono4000', 48000, TOPOLOGY.mono, { trimPercent: 60 }, null],
    // カーネルに収めるための切り詰め（末尾のフェード）が500フレームに全部かかる。
    ['j_stereo_trunc500', 'stereo800', 48000, TOPOLOGY.independent, {}, 500],
    ['k_stereo_co_plus2ms_dt200', 'stereo800', 48000, TOPOLOGY.independent, { cutOffsetMs: 2, decayPercent: 200 }, null]
];

function encodeFloats(array) {
    const bytes = Buffer.alloc(array.length * 4);
    for (let i = 0; i < array.length; i += 1) bytes.writeFloatLE(array[i], i * 4);
    return bytes.toString('base64');
}

function series(analysis) {
    return {
        frames: analysis.frames,
        sampleFrames: Array.from(analysis.sampleFrames),
        envelope: encodeFloats(analysis.envelope),
        edcDb: encodeFloats(analysis.edcDb),
        rt60Seconds: analysis.rt60Seconds
    };
}

function sha256(file) {
    return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

const out = {
    generator: 'Tools/ir_analysis_golden.mjs',
    upstream: {
        'js/ir-library/ir-preparation.js': sha256(preparationFile),
        'js/utils/measurement-dsp/onset.js': sha256(onsetFile)
    },
    inputs: Object.fromEntries(Object.entries(inputs).map(([name, channels]) => [name, channels.map(encodeFloats)])),
    cases: cases.map(([name, input, sampleRate, topology, overrides, emitMaxFrames]) => {
        const options = { ...defaults, ...overrides };
        const channels = inputs[input].map(channel => channel.slice());
        const paths = topology === TOPOLOGY.matrix
            ? Array.from({ length: Math.min(channels.length, 2) },
                (_, index) => ({ inputSlot: index, outputSlot: index, irChannel: index }))
            : undefined;
        const prepared = prepareIr({
            channels,
            sampleRate,
            options: {
                topology,
                directCut: options.directCut,
                cutOffsetMs: options.cutOffsetMs,
                decayPercent: options.decayPercent,
                trimPercent: options.trimPercent,
                maxFrames: channels[0].length,
                analysisPoints: 1600,
                paths
            }
        });
        const assetChannels = topology === TOPOLOGY.independent ? Math.min(2, channels.length) : undefined;
        const emitted = emitPreparedIr({
            channels: prepared.channels,
            sampleRate: prepared.sampleRate,
            analysis: prepared.analysis,
            options: {
                topology,
                assetChannels,
                paths,
                maxFrames: emitMaxFrames ?? prepared.frames,
                analysisPoints: 1600
            }
        });
        const analysis = emitted.analysis;
        return {
            name,
            input,
            sampleRate,
            topology,
            assetChannels: assetChannels ?? null,
            emitMaxFrames: emitMaxFrames ?? prepared.frames,
            options,
            expected: {
                frames: emitted.frames,
                onsetFrame: analysis.onsetFrame,
                cutFrame: analysis.cutFrame,
                sourceStartFrame: analysis.sourceStartFrame,
                original: series(analysis.original),
                current: series(analysis)
            }
        };
    })
};

fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, JSON.stringify(out, null, 1) + '\n');
console.log(`wrote ${path.relative(root, outFile)} (${out.cases.length} cases, ${fs.statSync(outFile).size} bytes)`);
