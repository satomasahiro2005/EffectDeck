// sfz_golden.mjs
// SFZ Note Player の取り込み（SFZ の読み・バンクの入れ物と鍵・資産の並び・準備）の見本を、
// 上流の js/sfz/*.js そのものに作らせる。
//
// 鍵（バンクの id）が上流とずれると、PC の EffeTune で同じフォルダを取り込んだのに、鎖の `sf` が互いを
// 指せなくなる（PC に「Missing SFZ」が出る）。資産の並びがずれるとカーネルが黙って弾く。
// 入力（SFZ の本文・小さな WAV・領域）と上流の答えの両方を Tests/Fixtures/SFZ/sfz-golden.json へ書く。
// 入力は Tools/golden/sfz_cases.mjs、走らせ方は Tools/golden/sfz_runner.mjs（束ねの試験と共有）。
//
//   root=$(bash Tools/golden/extract_pin.sh)
//   EFFETUNE_ROOT="$root" node Tools/golden/sfz_golden.mjs [出力先]
//
// 次も書く。
//   Tests/Fixtures/SFZ/payloads/*.bin   カーネルへ送る入れ物（v6・v7・FX・v8）。ネイティブの試験（Tests/Native）が読む
//   JSON の admission 節                上流が持つ plugins/dsp/effetune-dsp.wasm へ payload を渡して、最後の状態だけ（バイトは持たない）
//
// **見積りの値（footprint）は上流のカーネルから取らない。**見本に置くのは、固定の見積りを通した足し算の式まで。
// 0.16 のころの入れ物（Tests/Fixtures/SFZ/legacy-banks.json）は入力として固定で、ここでは作り直さない。

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { buildInputs, expectedFor } from './sfz_cases.mjs';
import { b64, fixedRandom, fromB64, mergedWarnings } from './sfz_runner.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.join(here, '..', '..');
const upstream = process.env.EFFETUNE_ROOT;
if (!upstream) {
    console.error('sfz_golden.mjs: EFFETUNE_ROOT が無い（bash Tools/golden/extract_pin.sh の出力を渡す）');
    process.exit(2);
}
const fixtures = path.join(repo, 'Tests', 'Fixtures', 'SFZ');
const outFile = path.resolve(process.argv[2] ?? path.join(fixtures, 'sfz-golden.json'));
const payloadDir = process.argv[2] ? path.join(path.dirname(outFile), 'payloads') : path.join(fixtures, 'payloads');
const load = file => import(pathToFileURL(path.resolve(upstream, file)).href);
const [parser, bank, asset, service, context] = await Promise.all(['parser', 'bank', 'asset', 'service', 'preparation-context'].map(name => load(`js/sfz/${name}.js`)));
const api = { ...parser, ...bank, ...asset, ...service, ...context };

// 取り込みの id（12 バイトの乱数）を決まった値にする。上流は globalThis.crypto.getRandomValues を呼ぶ
Object.defineProperty(globalThis, 'crypto', { configurable: true, writable: true,
    value: { subtle: crypto.webcrypto.subtle, getRandomValues: bytes => fixedRandom(bytes) } });
const ctx = { U8: Uint8Array, F32: Float32Array, Blob, File };

const legacy = JSON.parse(fs.readFileSync(path.join(fixtures, 'legacy-banks.json'), 'utf8'));
const { audio, sections } = buildInputs(legacy);

const golden = {
    note: 'Tools/golden/sfz_golden.mjs が上流の js/sfz/*.js に作らせた。手で直さない。',
    runner: 'Tools/golden/sfz_runner.mjs（見積りは固定: 4096 + 64*処理チャンネル + maxFrames、取り込みの id の乱数は a0a1…ab、importedAt は 2026-01-01）',
    regionFields: api.SFZ_REGION_FIELDS,
    audio: Object.fromEntries(Object.entries(audio).map(([name, bytes]) => [name, b64(bytes)]))
};
for (const [name, input] of Object.entries(sections)) {
    if (name === 'budget') {
        golden.budget = { regions: input.regions, definitionBytes: input.definitionBytes, cases: [] };
        for (const item of input.cases) {
            golden.budget.cases.push({ ...item, expected: await expectedFor('budget', api, ctx, item, audio, { budget: input }) });
        }
        continue;
    }
    golden[name] = [];
    for (const item of input.paths ? [input] : input) {
        const expected = await expectedFor(name, api, ctx, item, audio, {});
        golden[name].push({ ...item, expected });
    }
}
golden.folder = golden.folder[0];
golden.merged = mergedWarnings(api);

// ---- カーネルへ送る入れ物と、そのカーネルの受け入れ ----

// 見本に入る入れ物の一覧（取り込みと、0.16 の入れ物の読み直し）。失敗した件（error）は入らない
const payloads = [];
const add = (source, name, base64, kind) => base64 && payloads.push({ source, name: `${source}-${name}`, kind, payload: base64 });
for (const item of golden.asset) add('asset', item.name, item.expected.payload?.b64, 'prepared');
for (const item of golden.imports) {
    add('imports', item.name, item.expected.prepared?.payload?.b64, 'prepared');
    // 流し込みの host で開き直したときだけ違うバイトになる件（ほかは取り込み時と同じ）
    if (item.expected.reopenedOnStreamHost?.payload?.b64) add('imports-streamhost', item.name, item.expected.reopenedOnStreamHost.payload.b64, 'prepared');
    if (item.expected.reopened?.payload?.b64) add('imports-reopened', item.name, item.expected.reopened.payload.b64, 'prepared');
}
for (const item of golden.streamedImports) add('streamed', item.name, item.expected.prepared?.payload?.b64, 'streamed');
for (const item of golden.migration) {
    add('migration', item.name, item.expected.plain?.payload?.b64, 'prepared');
    if (item.expected.streamHost?.payload?.b64) add('migration-streamhost', item.name, item.expected.streamHost.payload.b64, 'prepared');
}

// 同じバイトは 1 回だけ
const unique = [];
const seen = new Map();
for (const item of payloads) {
    const digest = crypto.createHash('sha256').update(item.payload).digest('hex');
    if (seen.has(digest)) { seen.get(digest).also.push(item.name); continue; }
    const entry = { ...item, sha256: digest, also: [] };
    seen.set(digest, entry);
    unique.push(entry);
}
// 自分の分だけ消す（sf2-*.bin は sf2_golden.mjs のもの）
fs.mkdirSync(payloadDir, { recursive: true });
for (const file of fs.readdirSync(payloadDir)) if (!file.startsWith('sf2-')) fs.rmSync(path.join(payloadDir, file));
const words = bytes => new Uint32Array(bytes.buffer, bytes.byteOffset + 32, 2);
golden.payloads = unique.map(item => {
    const bytes = fromB64(item.payload);
    const file = `${item.name}.bin`;
    fs.writeFileSync(path.join(payloadDir, file), bytes);
    return { file: `payloads/${file}`, sha256: item.sha256, kind: item.kind, tableVersion: new Uint32Array(bytes.buffer.slice(bytes.byteOffset + 32, bytes.byteOffset + 40))[1],
        bytes: bytes.length, also: item.also };
});

// 受け入れ: 上流が持つ wasm（baseline と simd）へ、見積り → 送り込み → 処理、の順で。ACTIVE（3）になることだけ記録する。
// ストリーミングの入れ物（v8）は et_instance_stream_configure が要るので、ここでは見ない（Tests/Native が見る）
const wasm = variant => fs.readFileSync(path.resolve(upstream, 'plugins', 'dsp', `effetune-dsp${variant === 'simd' ? '.simd' : ''}.wasm`));
const { instantiateDspBinding } = await load('js/audio/dsp-engine-binding.js');
const { DSP_PARAM_PACKERS } = await load('js/audio/dsp-params.generated.js');
const { materializeAcceptanceAsset } = await load('tests/helpers/sfz-native-acceptance.mjs');

async function admit(variant, payloadBase64) {
    const module = await WebAssembly.compile(wasm(variant));
    const control = await instantiateDspBinding(module);
    const binding = await instantiateDspBinding(module);
    const sampleRate = 48000, channels = 2, block = 128;
    try {
        const payload = fromB64(payloadBase64).buffer;
        const samples = new DataView(payload).getUint32(8, true);
        const base = { payload, samples, channels: 1, sampleRate: 1, layout: 0, formatTag: 1, rateDivider: 1, headBlock: 128,
            processingChannels: 1, footprintBytes: payload.byteLength };
        const prepared = await materializeAcceptanceAsset(control, base, { sampleRate, channels, maxFrames: block, playerKind: 'SFZNotePlayerPlugin' });
        binding.createEngine();
        if (binding.prepare(sampleRate, channels, block, 262144) !== 0) return 'prepare-failed';
        const id = binding.createInstance('SFZNotePlayerPlugin');
        const packer = DSP_PARAM_PACKERS.get('SFZNotePlayerPlugin');
        if (binding.instanceSetParams(id, packer.pack(), packer.hash) !== 0) return 'params-failed';
        if (binding.instanceSetAsset(id, 0, prepared.payload, { ...prepared, frames: prepared.samples, topology: 0 }) !== 0) return 'set-asset-failed';
        const { combined, offsets } = binding.getArenaViews();
        let state = 0;
        for (let step = 0; step < 400; step++) {
            combined.fill(0);
            if (binding.instanceProcess(id, offsets.combined, channels, block, step * block / sampleRate) !== 0) return 'process-failed';
            state = binding.instanceAssetState(id, 0) & 0xff;
            if (state === 3 || state === 4) break;
        }
        return state === 3 ? 'active' : `state-${state}`;
    } finally {
        try { binding.destroyEngine(); } catch { /* 作れなかったとき */ }
        try { control.destroyEngine(); } catch { /* 作っていない */ }
    }
}

golden.admission = [];
for (const item of unique.filter(entry => entry.kind === 'prepared')) {
    let baseline; try { baseline = await admit('baseline', item.payload); } catch (e) { baseline = 'throw: ' + e.message; }
    let simd; try { simd = await admit('simd', item.payload); } catch (e) { simd = 'throw: ' + e.message; }
    golden.admission.push({ name: item.name, baseline, simd });
    if (baseline !== 'active' || simd !== 'active') console.error(`admission ${item.name}: baseline=${baseline} simd=${simd}`);
}
const refused = golden.admission.filter(item => item.baseline !== 'active' || item.simd !== 'active');
if (refused.length) {
    console.error(`sfz_golden.mjs: ${refused.length} 件の payload がカーネルに受け入れられない（上の admission）`);
    process.exitCode = 1;
}

fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, JSON.stringify(golden, null, 1) + '\n');
console.log('wrote', outFile, `(${unique.length} payloads, ${golden.admission.length} admitted)`);
