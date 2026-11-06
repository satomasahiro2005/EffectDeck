// sf2_golden.mjs
// SoundFont（js/sf2）の見本を、上流の js/sf2/*.js そのものに作らせる。
// 入力は、上流の試験が使う SF2 の作り手（tests/helpers/sf2-fixture.mjs）の出力。操作は上流の tests/esm/sf2-parser.test.mjs の
// 11 の試験と同じ（Tools/golden/sf2_runner.mjs。束ねの試験 Tools/sfzjs/bundle.test.mjs と共有）。
// 続けて、v9 の入れ物が、上流のネイティブの試験が持つ kSf2NativeFixture（dsp/plugins/others/soundfont_player/sf2_fixture.h）と
// 1 バイトも違わないことを確かめる（違えば止まる）。
//
//   root=$(bash Tools/golden/extract_pin.sh)
//   EFFETUNE_ROOT="$root" node Tools/golden/sf2_golden.mjs [出力先]
//
// 出力: Tests/Fixtures/SFZ/sf2-golden.json と、Tests/Fixtures/SFZ/payloads/sf2-*.bin（Tests/Native が読む v9 の入れ物）

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { runSf2Case } from './sf2_runner.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.join(here, '..', '..');
const upstream = process.env.EFFETUNE_ROOT;
if (!upstream) {
    console.error('sf2_golden.mjs: EFFETUNE_ROOT が無い（bash Tools/golden/extract_pin.sh の出力を渡す）');
    process.exit(2);
}
const fixtures = path.join(repo, 'Tests', 'Fixtures', 'SFZ');
const outFile = path.resolve(process.argv[2] ?? path.join(fixtures, 'sf2-golden.json'));
const payloadDir = process.argv[2] ? path.join(path.dirname(outFile), 'payloads') : path.join(fixtures, 'payloads');
const load = file => import(pathToFileURL(path.resolve(upstream, file)).href);
const [{ createSf2Fixture }, { createSf2NativeFixture }, parser, compiler, source, asset, modulation, sfzAsset] = await Promise.all([
    load('tests/helpers/sf2-fixture.mjs'), load('tools/generate-sf2-native-fixture.mjs'), load('js/sf2/parser.js'), load('js/sf2/compiler.js'),
    load('js/sf2/source.js'), load('js/sf2/asset.js'), load('js/sf2/modulation.js'), load('js/sfz/asset.js')]);
const api = { ...parser, ...compiler, ...source, ...asset, ...modulation, packStreamedSfzAsset: sfzAsset.packStreamedSfzAsset };
const ctx = { U8: Uint8Array, F64: Float64Array };
const b64 = bytes => Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString('base64');
const fixture = options => b64(createSf2Fixture(options));

const tones = Array.from({ length: 16 }, (_, channel) => ({ name: `Tone ${channel + 1}`, bank: channel === 9 ? 128 : channel, program: 127 - channel }));
const nativeBytes = await createSf2NativeFixture();
const cases = [
    { name: 'basic', kind: 'basic', fixture: fixture() },
    { name: 'key-range', kind: 'basic', fixture: fixture({ keyRange: [10, 20], sampleRate: 48000 }) },
    { name: 'extra-modulators', kind: 'basic', fixture: fixture({ modulators: [{ source: 0, destination: 15, amount: 600 }, { source: 0, destination: 16, amount: 500 }] }) },
    ...[1, 3].flatMap(globalMode => [null, 0, 1, 3].map(localMode =>
        ({ name: `loop-defaults-global${globalMode}-local${localMode}`, kind: 'loop-defaults', globalMode, localMode, fixture: fixture() }))),
    { name: 'sm24-old-version', kind: 'parse-only', fixture: fixture({ version: 1 }) },
    { name: 'sm24-absent', kind: 'parse-only', fixture: fixture({ sm24: false }) },
    { name: 'invalid-index', kind: 'parse-only', fixture: fixture({ invalidIndex: true }) },
    { name: 'riff-length', kind: 'riff-length', fixture: fixture() },
    { name: 'huge-pool', kind: 'huge-pool', fixture: fixture() },
    { name: 'stereo-link', kind: 'stereo-link', fixture: fixture() },
    { name: 'chained-modulation', kind: 'chained-mod', fixture: fixture() },
    { name: 'preset-index', kind: 'preset-index', fixture: fixture() },
    { name: 'collection-16-presets', kind: 'basic', fixture: fixture({ presets: tones }) },
    { name: 'unpitched-255', kind: 'unpitched', fixture: fixture() },
    { name: 'v9-serialization', kind: 'v9', fixture: fixture() },
    // 上流のネイティブの試験が持つ入れ物（kSf2NativeFixture）と同じ作り方（createSf2NativeFixture の既定）
    { name: 'native-fixture', kind: 'native', fixture: fixture({ keyRange: [0, 127], sampleFrames: 64, loopStart: 8, loopEnd: 56, sampleRate: 48000,
        pcm16: Array(64).fill(8192), presets: [
            { name: 'Base', bank: 0, program: 0, attenuation: 0 }, { name: 'Quiet', bank: 0, program: 1, attenuation: 200 },
            { name: 'Other bank', bank: 1, program: 2, attenuation: 100 }, { name: 'Drums', bank: 128, program: 0, attenuation: 400 }],
        modulators: [{ source: 0, destination: 15, amount: 600 }, { source: 0, destination: 16, amount: 500 }] }) },
    { name: 'linked-route', kind: 'linked-route', fixture: '', modulators: [
        { source: 0x057f, destination: 48, amount: 2, amountSource: 0, transform: 2, link: -1 },
        { source: 0x81, destination: 0x8000, amount: 1, amountSource: 0, transform: 0, link: 0 },
        { source: 13, destination: 0x8000, amount: 1, amountSource: 0, transform: 0, link: 0 }] }
];
for (const item of cases) item.expected = await runSf2Case(api, ctx, item);

// 上流の native の試験が持つ kSf2NativeFixture と同じバイトか
const header = fs.readFileSync(path.resolve(upstream, 'dsp', 'plugins', 'others', 'soundfont_player', 'sf2_fixture.h'), 'utf8');
const match = /kSf2NativeFixture\s*\{([\s\S]*?)\};/.exec(header);
assert.ok(match, 'sf2_fixture.h に kSf2NativeFixture が無い');
const kernelBytes = Uint8Array.from(match[1].split(',').map(value => value.trim()).filter(Boolean).map(Number));
const native = cases.find(item => item.name === 'native-fixture').expected;
const mine = Uint8Array.from(Buffer.from(native.payload.b64, 'base64'));
assert.deepEqual(mine, kernelBytes, 'native-fixture が kSf2NativeFixture と違う');
assert.deepEqual(mine, new Uint8Array(nativeBytes.payload), 'native-fixture が createSf2NativeFixture と違う');
assert.ok(header.includes(`kSf2NativeFootprint = ${native.footprintBytes}u`), 'footprint が kSf2NativeFootprint と違う');

fs.mkdirSync(payloadDir, { recursive: true });
const written = [];
for (const name of ['v9-serialization', 'native-fixture']) {
    const payload = Buffer.from(cases.find(item => item.name === name).expected.payload.b64, 'base64');
    fs.writeFileSync(path.join(payloadDir, `sf2-${name}.bin`), payload);
    written.push({ file: `payloads/sf2-${name}.bin`, bytes: payload.length });
}
const golden = {
    note: 'Tools/golden/sf2_golden.mjs が上流の js/sf2/*.js に作らせた。手で直さない。',
    runner: 'Tools/golden/sf2_runner.mjs',
    kernelFixture: { header: 'dsp/plugins/others/soundfont_player/sf2_fixture.h', bytes: kernelBytes.length, equal: true },
    payloads: written,
    cases
};
fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, JSON.stringify(golden, null, 1) + '\n');
console.log('wrote', outFile, `(${cases.length} cases; kSf2NativeFixture ${kernelBytes.length} bytes equal)`);
