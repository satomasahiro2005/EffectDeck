// ir_prepare_golden.mjs
// IRの下ごしらえ（ETIRPreparation.prepare）の見本を、上流のprepareIrそのものに作らせる。
//
// 上流のjs/ir-library/ir-preparation.jsはDOMにもWebAudioにも触らないので、nodeでそのまま読める
// （読むのはir-asset-payload.jsとutils/measurement-dsp/onset.jsだけ）。
// 入力は決まった乱数で作り、入力と上流の答えの両方をTests/Fixtures/IR/prepare-golden.jsonへ書く。
// Swift側は入力を読んでprepareに通し、答えと照合する（Tests/Unit/IRPreparationTests.swift）。
//
//   root=$(bash Tools/golden/extract_pin.sh)
//   EFFETUNE_ROOT="$root" node Tools/ir_prepare_golden.mjs
//
// 上流の木は EFFETUNE_ROOT（Tools/golden/*.mjs と同じ）。無ければ Vendor/effetune を読む。
// 作業ツリーの Vendor/effetune は setup.sh のパッチや別の版が混ざることがあるので、見本は
// extract_pin.sh で指している版を展開したものから作る。
//
// 面はfloat32のリトルエンディアンをbase64で入れる。数字で書くより4分の1ほどの大きさで済み、
// ビットも落ちない。同じ入力を使い回す見本が多いので、入力はinputsにまとめて名前で引く。

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const effetune = path.resolve(process.env.EFFETUNE_ROOT || path.join(root, 'Vendor', 'effetune'));
const preparationFile = path.join(effetune, 'js', 'ir-library', 'ir-preparation.js');
const onsetFile = path.join(effetune, 'js', 'utils', 'measurement-dsp', 'onset.js');
const outFile = path.join(root, 'Tests', 'Fixtures', 'IR', 'prepare-golden.json');

const { prepareIr } = await import(pathToFileURL(preparationFile).href);

// ---- 入力 ----

function lcg(seed) {
    let state = seed >>> 0;
    return () => {
        state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
        return state / 4294967296 * 2 - 1;
    };
}

// 頭にlead個の0、次に直接音、その後に減衰する雑音。
function decayingIr({ frames, lead = 0, direct = 0.9, amplitude = 0.4, decay = 150, seed = 1, gap = 0 }) {
    const random = lcg(seed);
    const out = new Float32Array(frames);
    if (lead < frames) out[lead] = direct;
    for (let i = lead + 1 + gap; i < frames; i += 1) {
        out[i] = amplitude * random() * Math.exp(-(i - lead) / decay);
    }
    return out;
}

function zeros(frames) {
    return new Float32Array(frames);
}

const inputs = {
    mono700: [decayingIr({ frames: 700, lead: 37, seed: 11 })],
    stereo800: [
        decayingIr({ frames: 800, lead: 20, seed: 21, direct: 0.8 }),
        decayingIr({ frames: 800, lead: 20, seed: 22, direct: 0.5, amplitude: 0.25 })
    ],
    // 4面で大きさを変えてある。True Stereoは4面で1つの利得を持つので、それが見える。
    quad600: [
        decayingIr({ frames: 600, lead: 12, seed: 31, direct: 0.9 }),
        decayingIr({ frames: 600, lead: 12, seed: 32, direct: 0.3, amplitude: 0.15 }),
        decayingIr({ frames: 600, lead: 14, seed: 33, direct: 0.25, amplitude: 0.12 }),
        decayingIr({ frames: 600, lead: 13, seed: 34, direct: 0.7, amplitude: 0.35 })
    ],
    // 2048フレームの立ち下がりが一部だけかかる長さ（tr 60で2400フレーム残る）。
    mono4000: [decayingIr({ frames: 4000, lead: 5, seed: 41, decay: 900 })],
    // 直接音と残響の間が空いている（Direct Cutの後ろが静か）。
    monoGap500: [decayingIr({ frames: 500, lead: 9, seed: 51, gap: 30 })],
    stereoZero600: [decayingIr({ frames: 600, lead: 4, seed: 61 }), zeros(600)],
    mono100zero: [zeros(100)],
    mono40: [decayingIr({ frames: 40, lead: 3, seed: 71, decay: 10 })],
    mono1: [Float32Array.of(0.5)],
    // 最後のフレームだけ鳴っている。onsetも頭の無音も最後になり、開始が長さの内側へ押し戻される。
    monoLast64: (() => { const a = zeros(64); a[63] = 0.25; return [a]; })(),
    // 頭の無音なし、onsetが10フレーム目（小さい前触れの後に大きい直接音）。
    monoPre300: (() => {
        const a = decayingIr({ frames: 300, lead: 10, seed: 81, decay: 60 });
        for (let i = 0; i < 10; i += 1) a[i] = 0.001 * (i + 1);
        return [a];
    })(),
    triple500: [
        decayingIr({ frames: 500, lead: 6, seed: 91 }),
        decayingIr({ frames: 500, lead: 7, seed: 92, direct: 0.4 }),
        decayingIr({ frames: 500, lead: 8, seed: 93, direct: 0.2, amplitude: 0.1 })
    ]
};

// ---- 見本 ----

const defaults = { directCut: true, cutOffsetMs: 0, decayPercent: 100, trimPercent: 100 };
const TOPOLOGY = { mono: 1, independent: 2, trueStereo: 3, matrix: 4 };

const cases = [
    ['mono_dc', 'mono700', 48000, TOPOLOGY.mono, {}],
    ['mono_nodc', 'mono700', 48000, TOPOLOGY.mono, { directCut: false }],
    ['stereo_dc', 'stereo800', 48000, TOPOLOGY.independent, {}],
    ['stereo_nodc', 'stereo800', 48000, TOPOLOGY.independent, { directCut: false }],
    ['stereo_dt50_dc', 'stereo800', 48000, TOPOLOGY.independent, { decayPercent: 50 }],
    ['stereo_dt200_dc', 'stereo800', 48000, TOPOLOGY.independent, { decayPercent: 200 }],
    ['stereo_dt50_nodc', 'stereo800', 48000, TOPOLOGY.independent, { directCut: false, decayPercent: 50 }],
    ['stereo_dt200_nodc', 'stereo800', 48000, TOPOLOGY.independent, { directCut: false, decayPercent: 200 }],
    ['stereo_tr60_nodc', 'stereo800', 48000, TOPOLOGY.independent, { directCut: false, trimPercent: 60 }],
    ['stereo_44100_dc', 'stereo800', 44100, TOPOLOGY.independent, {}],
    ['stereo_96000_dc', 'stereo800', 96000, TOPOLOGY.independent, {}],
    ['ts_dc', 'quad600', 48000, TOPOLOGY.trueStereo, {}],
    ['ts_nodc', 'quad600', 48000, TOPOLOGY.trueStereo, { directCut: false }],
    ['ts_tr60_dc', 'quad600', 48000, TOPOLOGY.trueStereo, { trimPercent: 60 }],
    ['ts_tr60_dt200_nodc', 'quad600', 48000, TOPOLOGY.trueStereo, { directCut: false, trimPercent: 60, decayPercent: 200 }],
    ['ts_dt50_tr60_dc', 'quad600', 48000, TOPOLOGY.trueStereo, { decayPercent: 50, trimPercent: 60 }],
    ['mono_long_tr60_dc', 'mono4000', 48000, TOPOLOGY.mono, { trimPercent: 60 }],
    ['mono_long_tr60_dt200_dc', 'mono4000', 48000, TOPOLOGY.mono, { trimPercent: 60, decayPercent: 200 }],
    ['mono_gap_dc', 'monoGap500', 48000, TOPOLOGY.mono, {}],
    ['mono_co_plus2ms', 'mono700', 48000, TOPOLOGY.mono, { cutOffsetMs: 2 }],
    ['mono_co_minus0_5ms', 'mono700', 48000, TOPOLOGY.mono, { cutOffsetMs: -0.5 }],
    ['mono_co_minus20_fs8000', 'monoPre300', 8000, TOPOLOGY.mono, { cutOffsetMs: -20 }],
    // -0.1875ms × 8000Hz = -1.5フレーム。Math.roundは-1、0から遠い側へ丸めると-2。
    ['mono_co_minus_half_frame', 'monoPre300', 8000, TOPOLOGY.mono, { cutOffsetMs: -0.1875 }],
    ['mono_co_plus_half_frame', 'monoPre300', 8000, TOPOLOGY.mono, { cutOffsetMs: 0.1875 }],
    ['mono_pre_nodc_fs8000', 'monoPre300', 8000, TOPOLOGY.mono, { directCut: false }],
    ['stereo_zero_channel_dc', 'stereoZero600', 48000, TOPOLOGY.independent, {}],
    ['stereo_zero_channel_nodc', 'stereoZero600', 48000, TOPOLOGY.independent, { directCut: false }],
    ['mono_all_zero_dc', 'mono100zero', 48000, TOPOLOGY.mono, {}],
    ['mono_all_zero_nodc', 'mono100zero', 48000, TOPOLOGY.mono, { directCut: false }],
    ['mono_short40_dc', 'mono40', 48000, TOPOLOGY.mono, {}],
    ['mono_short40_tr60_nodc', 'mono40', 48000, TOPOLOGY.mono, { directCut: false, trimPercent: 60 }],
    ['mono_single_frame_dc', 'mono1', 48000, TOPOLOGY.mono, {}],
    ['mono_last_frame_dc', 'monoLast64', 48000, TOPOLOGY.mono, {}],
    ['mono_topology_two_channels_dc', 'stereo800', 48000, TOPOLOGY.mono, {}],
    ['matrix_three_channels_dc', 'triple500', 48000, TOPOLOGY.matrix, {}],
    ['matrix_three_channels_dt200_nodc', 'triple500', 48000, TOPOLOGY.matrix, { directCut: false, decayPercent: 200 }]
];

function encode(channel) {
    const bytes = Buffer.alloc(channel.length * 4);
    for (let i = 0; i < channel.length; i += 1) bytes.writeFloatLE(channel[i], i * 4);
    return bytes.toString('base64');
}

function sha256(file) {
    return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

const out = {
    generator: 'Tools/ir_prepare_golden.mjs',
    upstream: {
        'js/ir-library/ir-preparation.js': sha256(preparationFile),
        'js/utils/measurement-dsp/onset.js': sha256(onsetFile)
    },
    inputs: Object.fromEntries(Object.entries(inputs).map(([name, channels]) => [name, channels.map(encode)])),
    cases: cases.map(([name, input, sampleRate, topology, overrides]) => {
        const options = { ...defaults, ...overrides };
        const channels = inputs[input].map(channel => channel.slice());
        const result = prepareIr({
            channels,
            sampleRate,
            options: {
                topology,
                directCut: options.directCut,
                cutOffsetMs: options.cutOffsetMs,
                decayPercent: options.decayPercent,
                trimPercent: options.trimPercent,
                // ir_reverb.jsの_prepareHostPcmと同じ（maxFramesは面の長さ）。
                maxFrames: channels[0].length,
                // matrixはペイロードを組むのに経路が要る。面の中身には効かない。
                // 処理幅2への対角（ir-plugin-contract.jsのdiagonalPaths）。
                paths: topology === TOPOLOGY.matrix
                    ? Array.from({ length: Math.min(channels.length, 2) },
                        (_, index) => ({ inputSlot: index, outputSlot: index, irChannel: index }))
                    : undefined
            }
        });
        const analysis = result.analysis;
        return {
            name,
            input,
            sampleRate,
            topology,
            options,
            expected: {
                frames: result.frames,
                leadingSilenceFrames: analysis.leadingSilenceFrames,
                onsetFrame: analysis.onsetFrame,
                cutFrame: analysis.cutFrame,
                sourceStartFrame: analysis.sourceStartFrame,
                truncated: analysis.truncated,
                initialGains: Array.from(analysis.initialNormalizationGains),
                finalGains: Array.from(analysis.finalNormalizationGains),
                channels: result.channels.map(encode)
            }
        };
    })
};

fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, JSON.stringify(out, null, 1) + '\n');
console.log(`wrote ${path.relative(root, outFile)} (${out.cases.length} cases, ${fs.statSync(outFile).size} bytes)`);
