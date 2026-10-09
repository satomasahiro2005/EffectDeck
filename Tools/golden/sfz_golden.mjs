// sfz_golden.mjs
// SFZ Note Player の取り込み（SFZ の読み・バンクの入れ物と鍵・資産の並び・予算への収め方）の見本を、
// 上流の js/sfz/*.js そのものに作らせる。
//
// 鍵（バンクの id）が上流とずれると、PC の EffeTune で同じフォルダを取り込んだのに、鎖の `sf` が互いを
// 指せなくなる（PC に「Missing SFZ」が出る）。資産の並びがずれるとカーネルが黙って弾く。
// 入力（SFZ の本文・小さな WAV・領域）と上流の答えの両方を Tests/Fixtures/SFZ/sfz-golden.json へ書く。
// Swift 側は入力を読んで同じ処理を走らせ、答えと照合する（Tests/Unit/SFZTests.swift）。
//
//   root=$(bash Tools/golden/extract_pin.sh)
//   EFFETUNE_ROOT="$root" node Tools/golden/sfz_golden.mjs [出力先]
//
// 音のファイルは 16 bit PCM の小さな WAV を作る（上流のヘッダ読みが読める形）。上流の decode の代わりに、
// この WAV を読む小さな関数を渡す。Swift の試験も同じ読みをするので、読みの差は入らない。

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.join(here, '..', '..');
const upstream = process.env.EFFETUNE_ROOT;
if (!upstream) {
    console.error('sfz_golden.mjs: EFFETUNE_ROOT が無い（bash Tools/golden/extract_pin.sh の出力を渡す）');
    process.exit(2);
}
const outFile = path.resolve(process.argv[2] ?? path.join(repo, 'Tests', 'Fixtures', 'SFZ', 'sfz-golden.json'));
const load = file => import(pathToFileURL(path.resolve(upstream, 'js', 'sfz', file)).href);
const { parseSfz, normalizeSfzPath } = await load('parser.js');
const { encodeSfzBank, decodeSfzBank, identifySfzBank, estimateSfzBankBytes } = await load('bank.js');
const { packSfzAsset, SFZ_REGION_FIELDS } = await load('asset.js');
const { SfzLibraryService, selectSfzRegionsForBudget, mergeSfzWarnings, listSfzFolderFiles } = await load('service.js');

const encoder = new TextEncoder();
const b64 = bytes => Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString('base64');
const fromB64 = text => new Uint8Array(Buffer.from(text, 'base64'));

// ---- 音: 16 bit PCM の WAV ----

function wav({ channels, rate, frames, seed }) {
    const data = new DataView(new ArrayBuffer(frames * channels * 2));
    let state = seed >>> 0;
    for (let i = 0; i < frames * channels; i++) {
        state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
        data.setInt16(i * 2, (state >>> 16) - 32768 >> 1, true);
    }
    const bytes = new Uint8Array(44 + data.byteLength);
    const view = new DataView(bytes.buffer);
    bytes.set(encoder.encode('RIFF'), 0);
    view.setUint32(4, 36 + data.byteLength, true);
    bytes.set(encoder.encode('WAVEfmt '), 8);
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, channels, true);
    view.setUint32(24, rate, true);
    view.setUint32(28, rate * channels * 2, true);
    view.setUint16(32, channels * 2, true);
    view.setUint16(34, 16, true);
    bytes.set(encoder.encode('data'), 36);
    view.setUint32(40, data.byteLength, true);
    bytes.set(new Uint8Array(data.buffer), 44);
    return bytes;
}

// 試験用の decode。WAV の 16 bit PCM を float の面へ（/ 32768）。Swift の試験も同じ式。
function decodeWav(input) {
    const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const channels = view.getUint16(22, true);
    const sampleRate = view.getUint32(24, true);
    const frames = (view.getUint32(40, true)) / (channels * 2);
    const planes = Array.from({ length: channels }, () => new Float32Array(frames));
    for (let f = 0; f < frames; f++) {
        for (let c = 0; c < channels; c++) planes[c][f] = view.getInt16(44 + (f * channels + c) * 2, true) / 32768;
    }
    return { sampleRate, channels: planes };
}

const fixtures = {
    'a.wav': { channels: 1, rate: 48000, frames: 600, seed: 1 },
    'b one.wav': { channels: 2, rate: 44100, frames: 500, seed: 2 },
    'c.wav': { channels: 1, rate: 48000, frames: 300, seed: 3 },
    'samples/d.wav': { channels: 2, rate: 48000, frames: 400, seed: 4 },
    'samples/e.wav': { channels: 1, rate: 22050, frames: 250, seed: 5 },
    'x.wav': { channels: 1, rate: 48000, frames: 100, seed: 6 },
    'sfz/c.wav': { channels: 1, rate: 48000, frames: 200, seed: 7 },
    'samples/f.wav': { channels: 2, rate: 48000, frames: 600, seed: 8 },
    'samples/g.wav': { channels: 1, rate: 44100, frames: 300, seed: 9 }
};
const audio = Object.fromEntries(Object.entries(fixtures).map(([name, spec]) => [name, wav(spec)]));

// ---- 1. パーサ ----

const text = {
    basic: `<global> volume=-3 // comment
<group> lovel=1 hivel=64
<region> sample=a.wav key=c4
<region> sample="b one.wav" lokey=d4 hikey=e4 loop_mode=loop_continuous loop_start=10 loop_end=2000 ampeg_release=0.5
/* block
comment */ <group> lovel=65 hivel=127 seq_length=2 seq_position=2
<region> sample=c.wav lokey=c#3 hikey=db4 pitch_keycenter=e3 tune=-12 pan=25.5
`,
    defines: `#define $NAME a.wav
#define $LO 60
<region> sample=$NAME lokey=$LO hikey=62
<region> sample=$OTHER lokey=65 hikey=65
#include "inc/more.sfz"
`,
    include: `// first
<region> sample=c.wav key=48`,
    'inc/more.sfz': `#define $OTHER c.wav
<control> default_path=samples\\
<region> sample=d.wav key=72 offset=5 end=200 loop_mode=one_shot loop_start=500 loop_end=100
`,
    control: `<control>
set_cc1=64
set_cc7=90
default_path=samples/
<global> hicc7=100
<group> locc1=70
<region> sample=d.wav key=60
<group> locc1=60 hicc1=70
<region> sample=d.wav key=61
<region> sample=e.wav key=62 trigger=release
<region> sample=e.wav key=63 trigger=attack
<region> sample=e.wav key=64 sw_last=c2
<region> sample=e.wav key=65 sw_last=c2 sw_default=c2
`,
    invalid: `<region> sample=a.wav lokey=200 hikey=210
<region> sample=a.wav key=60 seq_length=2 seq_position=3
<region> sample=a.wav key=61 loop_mode=bogus
<region> sample=a.wav key=62.5
<region> sample=a.wav key=63 pitch_keytrack=5000
<region> sample=a.wav key=64
<region> key=65
<region> sample=nowhere.wav key=66
<region> sample=a.wav key=67 cutoff=100 fil_type=lpf_2p
`,
    spaces: `<region> sample=b one.wav key=60   lovel=0   hivel=100 amp_veltrack=-50
<region> sample="samples/d.wav" key=61
<region> sample=samples/../samples/e.wav key=62 transpose=-2 volume=6.5
`,
    groups: `<global> pan=10
<master> pan=20
<group> pan=30
<region> sample=a.wav key=60
<region> sample=a.wav key=61 pan=-5
<group>
<region> sample=a.wav key=62
<master> volume=-1
<region> sample=a.wav key=63
<global>
<region> sample=a.wav key=64
`,
    recursive: '#include "recursive.sfz"\n<region> sample=a.wav key=60',
    escape: '<region> sample=../outside.wav key=60',
    absolute: '#include "/etc/passwd"',
    missingInclude: '#include "nothing.sfz"'
};
const parserCases = [
    { name: 'basic', files: { 'basic.sfz': text.basic }, selected: 'basic.sfz' },
    { name: 'defines-include', files: { 'defines.sfz': text.defines, 'inc/more.sfz': text['inc/more.sfz'] }, selected: 'defines.sfz' },
    { name: 'control', files: { 'control.sfz': text.control }, selected: 'control.sfz' },
    { name: 'invalid', files: { 'invalid.sfz': text.invalid }, selected: 'invalid.sfz' },
    { name: 'spaces', files: { 'spaces.sfz': text.spaces }, selected: 'spaces.sfz' },
    { name: 'groups', files: { 'groups.sfz': text.groups }, selected: 'groups.sfz' },
    { name: 'in-folder', files: { 'sfz/inst.sfz': text.include }, selected: 'sfz/inst.sfz' },
    { name: 'recursive', files: { 'recursive.sfz': text.recursive }, selected: 'recursive.sfz' },
    { name: 'escape', files: { 'escape.sfz': text.escape }, selected: 'escape.sfz' },
    { name: 'absolute', files: { 'absolute.sfz': text.absolute }, selected: 'absolute.sfz' },
    { name: 'missing-include', files: { 'missing.sfz': text.missingInclude }, selected: 'missing.sfz' },
    { name: 'too-large', files: { 'big.sfz': '<region> sample=a.wav key=60 '.repeat(40) }, selected: 'big.sfz', maxBytes: 200 }
];
const sampleNames = Object.keys(audio);
const encoded = value => JSON.parse(JSON.stringify(value, (key, v) => (v === undefined ? null : v)));
for (const testCase of parserCases) {
    const files = new Map(Object.entries(testCase.files).map(([name, body]) => [name, body]));
    try {
        const result = await parseSfz({
            selectedPath: testCase.selected,
            readText: async file => files.get(file) ?? null,
            hasSample: file => sampleNames.includes(file),
            maxBytes: testCase.maxBytes ?? 256 * 1024 * 1024,
            onDiagnostic: () => {}
        });
        // 領域の欠けた鍵（undefined）は null に揃える。
        testCase.expected = encoded(result);
    } catch (error) {
        testCase.expected = { error: error.code, message: error.message };
    }
}

// ---- 2. バンク ----

const bankFiles = new Map([
    ['inst.sfz', encoder.encode('<region> sample=a.wav key=60')],
    ['a.wav', audio['a.wav']],
    ['samples/é日本.wav', audio['c.wav']],
    ['quote"back\\slash.txt', encoder.encode('x')]
]);
const bankCases = [];
for (const warnings of [[], [{ code: 'reduced-bank', count: 1 }, { code: 'invalid-regions', count: 3 }]]) {
    const bytes = encodeSfzBank('inst.sfz', bankFiles, { warnings });
    const decoded = decodeSfzBank(bytes);
    bankCases.push({
        selectedPath: 'inst.sfz',
        files: Object.fromEntries([...bankFiles].map(([name, data]) => [name, b64(data)])),
        warnings,
        container: b64(bytes),
        id: await identifySfzBank(bytes),
        estimate: estimateSfzBankBytes('inst.sfz', new Map([...bankFiles].map(([name, data]) => [name, data.byteLength]))),
        decoded: { selectedPath: decoded.selectedPath, warnings: decoded.warnings, paths: [...decoded.files.keys()] }
    });
}
const badBanks = [];
{
    const good = encodeSfzBank('inst.sfz', bankFiles);
    const corrupt = (name, mutate) => { const copy = good.slice(); mutate(copy, new DataView(copy.buffer)); badBanks.push({ name, bytes: b64(copy) }); };
    corrupt('magic', (b, v) => v.setUint32(0, 1, true));
    corrupt('version', (b, v) => v.setUint32(4, 2, true));
    corrupt('metadata-length', (b, v) => v.setUint32(8, 0x7fffffff, true));
    badBanks.push({ name: 'truncated', bytes: b64(good.subarray(0, good.length - 3)) });
    for (const bank of badBanks) {
        try { decodeSfzBank(fromB64(bank.bytes)); bank.error = null; } catch (error) { bank.error = error.code ?? 'other'; }
    }
}

// ---- 3. 資産 ----

function pcmFor(name) {
    const decoded = decodeWav(audio[name]);
    return decoded;
}
const region = (sample, extra = {}) => ({
    lokey: 0, hikey: 127, lovel: 1, hivel: 127, lorand: 0, hirand: 1, seq_length: 1, seq_position: 1,
    pitch_keycenter: 60, pitch_keytrack: 100, transpose: 0, tune: 0, volume: 0, pan: 0, amp_veltrack: 100,
    offset: 0, loop_mode: 0, loop_start: 0, ampeg_attack: 0, ampeg_hold: 0, ampeg_decay: 0,
    ampeg_sustain: 100, ampeg_release: 0.001, sample, seqGroup: 0, ...extra
});
const assetCases = [
    {
        name: 'two-samples',
        regions: [region('a.wav', { lokey: 48, hikey: 59, seqGroup: 0 }),
            region('b one.wav', { lokey: 60, hikey: 71, seqGroup: 3, loop_mode: 2, loop_start: 10, loop_end: 400, end: 450 }),
            region('a.wav', { lokey: 72, hikey: 84, seqGroup: 3, pan: -25.5, tune: 7, ampeg_release: 0.5 })],
        samples: ['a.wav', 'b one.wav']
    },
    {
        name: 'bad-loop-oneshot',
        regions: [region('c.wav', { loop_mode: 1, loop_start: 999, loop_end: 5 }),
            region('c.wav', { lokey: 1, hikey: 2, offset: 5000 })],
        samples: ['c.wav']
    },
    {
        name: 'all-invalid',
        regions: [region('c.wav', { offset: 9999 })],
        samples: ['c.wav']
    },
    {
        name: 'too-large',
        regions: [region('a.wav')],
        samples: ['a.wav'],
        maxBytes: 1000
    }
];
for (const testCase of assetCases) {
    const samples = new Map(testCase.samples.map(name => [name, pcmFor(name)]));
    const warnings = [];
    try {
        const result = packSfzAsset(testCase.regions, samples, {
            maxBytes: testCase.maxBytes ?? 256 * 1024 * 1024, onWarning: warning => warnings.push(warning), onDiagnostic: () => {}
        });
        testCase.expected = { payload: b64(new Uint8Array(result.payload)), footprintBytes: result.footprintBytes,
            samples: result.samples, channels: result.channels, sampleRate: result.sampleRate, layout: result.layout,
            formatTag: result.formatTag, rateDivider: result.rateDivider, headBlock: result.headBlock,
            processingChannels: result.processingChannels, warnings };
    } catch (error) {
        testCase.expected = { error: error.code, message: error.message };
    }
    testCase.samples = testCase.samples.map(name => ({ name, wav: b64(audio[name]) }));
}

// ---- 4. 予算 ----

const budgetRegions = [
    region('a.wav', { lokey: 36, hikey: 59, lovel: 1, hivel: 63 }),
    region('a.wav', { lokey: 36, hikey: 59, lovel: 64, hivel: 127 }),
    region('b one.wav', { lokey: 60, hikey: 71, seqGroup: 1 }),
    region('c.wav', { lokey: 72, hikey: 84, seqGroup: 1, lovel: 1, hivel: 80 }),
    region('x.wav', { lokey: 72, hikey: 84, seqGroup: 2, lovel: 81, hivel: 127 })
];
const budgetMetadata = new Map([
    ['a.wav', { size: audio['a.wav'].length, frames: 600, channels: 1 }],
    ['b one.wav', { size: audio['b one.wav'].length, frames: 500, channels: 2 }],
    ['c.wav', { size: audio['c.wav'].length, frames: 300, channels: 1 }],
    ['x.wav', { size: audio['x.wav'].length, frames: 100, channels: 1 }]
]);
const budgetCases = [];
for (const maxBytes of [1 << 20, 9400, 9000, 8700, 8000, 500]) {
    try {
        const selection = selectSfzRegionsForBudget(budgetRegions, budgetMetadata, maxBytes, 100);
        budgetCases.push({ maxBytes, expected: encoded(selection) });
    } catch (error) {
        budgetCases.push({ maxBytes, expected: { error: error.code, message: error.message } });
    }
}

// ---- 5. フォルダの取り込み（鍵・バンク・資産まで通す）----

class FakeFile {
    constructor(name, bytes) { this.name = name; this.webkitRelativePath = name; this._bytes = bytes; this.size = bytes.length; }
    async arrayBuffer() { return this._bytes.slice().buffer; }
    slice(start, end) { return new FakeFile(this.name, this._bytes.slice(start, end)); }
}
const importCases = [];
async function runImport(name, folder, selected, maxBytes) {
    const written = new Map();
    const backend = {
        cleanupTemporary: async () => {}, read: async key => written.get(key) ?? null,
        writeAtomic: async (key, bytes) => { written.set(key, bytes); }, remove: async key => { written.delete(key); }
    };
    const service = await new SfzLibraryService(backend, { getMaxBytes: () => maxBytes, onDiagnostic: () => {} }).open();
    const files = Object.entries(folder).map(([file, body]) => {
        const bytes = typeof body === 'string' ? encoder.encode(body) : body;
        return new FakeFile(`root/${file}`, bytes);
    });
    const record = { name, folder: Object.fromEntries(Object.entries(folder).map(([file, body]) =>
        [file, typeof body === 'string' ? { text: body } : { b64: b64(body) }])), selected, maxBytes };
    try {
        const entry = await service.importFolderFiles(files, selected, { decode: async bytes => decodeWav(bytes) });
        const bank = written.get(`${entry.id}.sfzbank`);
        const prepared = service.prepared.value;
        record.expected = { entry, bank: b64(bank), payload: b64(new Uint8Array(prepared.descriptor.payload)),
            warnings: prepared.warnings ?? [], footprintBytes: prepared.descriptor.footprintBytes };
    } catch (error) {
        record.expected = { error: error.code, message: error.message };
    }
    importCases.push(record);
}
const importFolder = {
    'piano.sfz': '<control> default_path=samples/\n<group> lovel=1 hivel=63\n<region> sample=d.wav lokey=36 hikey=47\n<region> sample=e.wav lokey=48 hikey=59\n<group> lovel=64 hivel=127\n<region> sample=f.wav lokey=36 hikey=47\n<region> sample=g.wav lokey=48 hikey=59 cutoff=200\n<region> sample=missing.wav lokey=60 hikey=61',
    'other.sfz': '<region> sample=samples/e.wav key=64',
    'samples/d.wav': audio['samples/d.wav'],
    'samples/e.wav': audio['samples/e.wav'],
    'samples/f.wav': audio['samples/f.wav'],
    'samples/g.wav': audio['samples/g.wav'],
    'notes.txt': 'unrelated'
};
await runImport('plain', importFolder, 'piano.sfz', 256 * 1024 * 1024);
await runImport('other', importFolder, 'other.sfz', 256 * 1024 * 1024);
for (const limit of [12000, 10000, 9000, 8000, 7000, 6500, 6000, 5500, 5000, 600]) {
    await runImport(`limit-${limit}`, importFolder, 'piano.sfz', limit);
}
await runImport('no-regions', { 'empty.sfz': '<region> sample=gone.wav key=60' }, 'empty.sfz', 256 * 1024 * 1024);

const folderList = ['root/a.sfz', 'root/b/c.SFZ', 'root/d.wav', 'root/b/e.sfz'];
const folderCase = { paths: folderList, expected: listSfzFolderFiles(folderList.map(name => new FakeFile(name, new Uint8Array(1)))) };

const merged = mergeSfzWarnings([{ code: 'invalid-regions', count: 2 }, { code: 'reduced-bank', count: 1 }],
    [{ code: 'invalid-regions', count: 5 }], undefined, [{ code: 'loop-points-ignored', count: 1 }]);

const normalizeCases = ['a/b.sfz', 'a\\b\\c.sfz', './x//y', 'a/../b', 'a/../../b', '/abs', 'C:/x', 'a/./b/.'].map(input => {
    try { return { input, expected: normalizeSfzPath(input) }; } catch (error) { return { input, error: error.code }; }
});
const normalizeWithDir = ['../x.wav', 'y/../../z', 'k.wav'].map(input => {
    try { return { input, directory: 'sub/dir', expected: normalizeSfzPath(input, 'sub/dir') }; } catch (error) { return { input, directory: 'sub/dir', error: error.code }; }
});

const golden = {
    note: 'Tools/golden/sfz_golden.mjs が上流の js/sfz/*.js に作らせた。手で直さない。',
    regionFields: SFZ_REGION_FIELDS,
    audio: Object.fromEntries(Object.entries(audio).map(([name, bytes]) => [name, b64(bytes)])),
    parser: parserCases, bank: bankCases, badBanks, asset: assetCases, budget: { regions: budgetRegions,
        metadata: Object.fromEntries(budgetMetadata), cases: budgetCases },
    imports: importCases, folder: folderCase, merged, normalize: [...normalizeCases, ...normalizeWithDir]
};
fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, JSON.stringify(golden, null, 1) + '\n');
console.log('wrote', outFile);
