// Tools/golden/asset_golden.mjs
// 資産（ETA1ペイロード）と確保の見積りの見本を、上流のJSそのものに作らせる。
// Swift側はTests/Unit/AssetPayloadTests.swiftが同じ入力をAssetUpload（DSP/AssetPayload.swift）に通して照合する。
//
//   root=$(bash Tools/golden/extract_pin.sh)
//   EFFETUNE_ROOT="$root" node Tools/golden/asset_golden.mjs
//
// 読むのはjs/ir-library/ir-asset-payload.js（buildIrAssetPayload）と
// js/ir-library/ir-plugin-contract.js（estimateIrKernelCommitFootprint・maximumIrFramesForKernel・
// estimateIrConvolverMemoryUpperBound、書き出されていないconvolutionStages）。
// 書き出されていない関数は、モジュールの文面の末尾にexportを1行足してdata: URLで読む
// （上流のファイルには書かない）。
//
// 出力はTests/Fixtures/Asset/asset-golden.json。キーは並べ替えて書き、入力は決まった乱数で作るので、
// 同じ上流からは同じバイトが出る（CIのgeneratedジョブが作り直して差分を見る）。

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.join(here, '..', '..');
const root = path.resolve(process.env.EFFETUNE_ROOT || path.join(repo, 'Vendor', 'effetune'));
const outFile = path.join(repo, 'Tests', 'Fixtures', 'Asset', 'asset-golden.json');

const payloadFile = path.join(root, 'js', 'ir-library', 'ir-asset-payload.js');
const contractFile = path.join(root, 'js', 'ir-library', 'ir-plugin-contract.js');

// 書き出されていない関数も読む。相対のimportは絶対のfile: URLへ書き換える。
async function importWithPrivates(file, names) {
    let source = fs.readFileSync(file, 'utf8');
    source = source.replace(/(\bfrom\s+|\bimport\s+)(['"])(\.{1,2}\/[^'"]+)\2/g,
        (match, head, quote, specifier) => head + quote + new URL(specifier, pathToFileURL(file)).href + quote);
    source += '\nexport { ' + names.map(name => `${name} as __${name}`).join(', ') + ' };\n';
    return import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
}

const { buildIrAssetPayload, IR_ASSET_TOPOLOGY } = await import(pathToFileURL(payloadFile).href);
const contract = await importWithPrivates(contractFile, ['convolutionStages']);
const {
    estimateIrKernelCommitFootprint,
    estimateIrConvolverMemoryUpperBound,
    maximumIrFramesForKernel,
    IR_KERNEL_ASSET_CAPACITY_BYTES
} = contract;

// ---- 入力 ----

function lcg(seed) {
    let state = seed >>> 0;
    return () => {
        state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
        return state / 4294967296 * 2 - 1;
    };
}

function noise(frames, seed) {
    const random = lcg(seed);
    const out = new Float32Array(frames);
    for (let i = 0; i < frames; i += 1) out[i] = random();
    return out;
}

function channels(count, frames, seed) {
    return Array.from({ length: count }, (_, index) => noise(frames, seed * 100 + index));
}

// float32で表せる端の値。-0のビットも、非正規化数も、最大値も落とさずに運ぶ。
const specials = Float32Array.of(0, -0, 1, -1, 1.401298464324817e-45, -1.401298464324817e-45,
    1.1754943508222875e-38, 3.4028234663852886e38, -3.4028234663852886e38, 0.1, 1 / 3);

function diagonal(count) {
    return Array.from({ length: count }, (_, index) => ({ inputSlot: index, outputSlot: index, irChannel: index }));
}

// FIR Crossoverの並び（design-worker.js:24-27）。帯ごとにL→2b、R→2b+1。
function crossoverPaths(bands) {
    const paths = [];
    for (let band = 0; band < bands; band += 1) {
        paths.push({ inputSlot: 0, outputSlot: band * 2, irChannel: band });
        paths.push({ inputSlot: 1, outputSlot: band * 2 + 1, irChannel: band });
    }
    return paths;
}

const T = IR_ASSET_TOPOLOGY;
const payloadCases = [
    ['unspecified_1x1', channels(1, 1, 1), 48000, undefined, undefined],
    ['mono_1x37_44100', channels(1, 37, 2), 44100, T.mono, undefined],
    ['independent_2x64_96000', channels(2, 64, 3), 96000, T.independent, undefined],
    ['true_stereo_4x50', channels(4, 50, 4), 48000, T.trueStereo, undefined],
    ['independent_16x5', channels(16, 5, 5), 48000, T.independent, undefined],
    ['matrix_crossover_4band', channels(4, 16, 6), 48000, T.matrix, crossoverPaths(4)],
    ['matrix_diagonal_16', channels(16, 8, 7), 192000, T.matrix, diagonal(16)],
    ['matrix_one_path_high_slots', channels(2, 3, 8), 48000, T.matrix,
        [{ inputSlot: 0xffffffff, outputSlot: 0x80000000, irChannel: 1 }]],
    ['specials_rate1', [specials], 1, T.mono, undefined],
    ['max_rate', channels(1, 3, 9), 0xffffffff, T.unspecified, undefined],
    ['explicit_empty_paths', channels(2, 4, 10), 48000, T.independent, []]
];

function floatBase64(values) {
    const bytes = Buffer.alloc(values.length * 4);
    for (let i = 0; i < values.length; i += 1) bytes.writeFloatLE(values[i], i * 4);
    return bytes.toString('base64');
}

const payloads = payloadCases.map(([name, chans, sampleRate, topology, paths]) => {
    const request = { channels: chans, sampleRate };
    if (topology !== undefined) request.topology = topology;
    if (paths !== undefined) request.paths = paths;
    const payload = Buffer.from(buildIrAssetPayload(request));
    return {
        channels: chans.map(floatBase64),
        name,
        paths: (paths || []).map(p => [p.inputSlot, p.outputSlot, p.irChannel]),
        payload: payload.toString('base64'),
        sampleRate,
        topology: topology ?? T.unspecified
    };
});

// ---- 見積り ----

const heads = [0, 128, 256, 512, 1024];
const frameCounts = [1, 127, 128, 129, 1024, 4095, 8192, 8193, 16384, 48000, 131072, 262144, 1048576];
// matrix以外: [assetChannels, processingChannels]
const plainShapes = [[1, 1], [1, 2], [2, 2], [4, 2], [2, 8], [8, 6], [16, 16]];
// matrix: [assetChannels, processingChannels, pathCount, inputCount]
const matrixShapes = [[1, 1, 1, 1], [2, 2, 2, 2], [2, 4, 4, 2], [4, 8, 8, 2], [8, 2, 2, 2], [16, 16, 16, 16]];

function shapes() {
    const out = [];
    for (const topology of [T.unspecified, T.mono, T.independent, T.trueStereo]) {
        for (const [assetChannels, processingChannels] of plainShapes) {
            out.push({ topology, assetChannels, processingChannels, pathCount: 0, inputCount: 0 });
        }
    }
    for (const [assetChannels, processingChannels, pathCount, inputCount] of matrixShapes) {
        out.push({ topology: T.matrix, assetChannels, processingChannels, pathCount, inputCount });
    }
    return out;
}

const footprintColumns = ['topology', 'headBlock', 'assetChannels', 'processingChannels', 'pathCount',
    'inputCount', 'frames', 'footprint', 'convolver'];
const footprintRows = [];
for (const shape of shapes()) {
    for (const headBlock of heads) {
        for (const frames of frameCounts) {
            const args = { ...shape, headBlock, frames };
            footprintRows.push([shape.topology, headBlock, shape.assetChannels, shape.processingChannels,
                shape.pathCount, shape.inputCount, frames,
                estimateIrKernelCommitFootprint(args), estimateIrConvolverMemoryUpperBound(args)]);
        }
    }
}

const maximumColumns = ['topology', 'headBlock', 'assetChannels', 'processingChannels', 'pathCount',
    'inputCount', 'sourceFrames', 'maximumFrames'];
const maximumRows = [];
for (const shape of shapes()) {
    for (const headBlock of heads) {
        for (const sourceFrames of [1, 1000, 262144, 10000000]) {
            maximumRows.push([shape.topology, headBlock, shape.assetChannels, shape.processingChannels,
                shape.pathCount, shape.inputCount, sourceFrames,
                maximumIrFramesForKernel({ ...shape, headBlock, sourceFrames })]);
        }
    }
}

const stages = [];
for (const headBlock of heads) {
    for (const frames of [1, 128, 129, 256, 512, 1000, 4096, 8192, 8193, 20000, 1048576]) {
        stages.push({
            frames,
            headBlock,
            stages: contract.__convolutionStages(frames, headBlock).stages
                .map(s => [s.block, s.offset, s.segmentFrames])
        });
    }
}

// ---- 書き出し ----

function sha256(file) {
    const text = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
    return crypto.createHash('sha256').update(text).digest('hex');
}

const out = {
    capacityBytes: IR_KERNEL_ASSET_CAPACITY_BYTES,
    footprints: { columns: footprintColumns, rows: footprintRows },
    generator: 'Tools/golden/asset_golden.mjs',
    maximumFrames: { columns: maximumColumns, rows: maximumRows },
    payloads,
    stages,
    upstream: {
        'js/ir-library/ir-asset-payload.js': sha256(payloadFile),
        'js/ir-library/ir-plugin-contract.js': sha256(contractFile)
    }
};

// キーを並べ替え、配列の要素は1行に1つ（差分が読める形）で書く。
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
console.log(`wrote ${path.relative(repo, outFile)} (${payloads.length} payloads, ${footprintRows.length} footprints, `
    + `${maximumRows.length} maximumFrames, ${stages.length} stage sets, ${fs.statSync(outFile).size} bytes)`);
