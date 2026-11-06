// Tools/sfzjs/bundle.test.mjs
// 置いてある束ね（Resources/SFZ/effetune-sfz.js）を、プレリュードだけの素の realm（vm）で評価し、
// 見本（Tests/Fixtures/SFZ/sfz-golden.json・sf2-golden.json）の全件を同じ走らせ方（Tools/golden/sfz_runner.mjs・sf2_runner.mjs）で通して、
// 見本の答え（上流の js/sfz・js/sf2 を Node で直に動かして作ったもの）と 1 バイトも違わないことを見る。
// 型付き配列・Blob・File は、すべて束ねの realm のもの（上流の instanceof が別 realm で落ちないことも見る）。
//
//   node --test Tools/sfzjs/bundle.test.mjs
//
// 上流（Vendor/effetune）も esbuild も要らない。見本の作り直しは Tools/golden/sfz_golden.mjs・sf2_golden.mjs、
// 束ねの作り直しは Tools/sfzjs/build.mjs（どちらも CI の generated ジョブが回して差分を見る）。
//
// もう 1 つ。PCM の書き手（globalThis.__effectdeckSfzPoolWriter。ホストが標本を staging へ直に書く道）を差し込んだ道は、
// 標本の分が空のまま返るので、参照の書き手（JS の 1 浮動小数ずつ）で埋めると、差し込まない道と同じバイトになること。

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { expectedFor, fixedRandom, fromB64 } from '../golden/sfz_runner.mjs';
import { runSf2Case } from '../golden/sf2_runner.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const read = file => fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
const resources = path.join(repo, 'Sources', 'EffeTuneLive', 'Resources', 'SFZ');
const fixtures = path.join(repo, 'Tests', 'Fixtures', 'SFZ');
const golden = JSON.parse(read(path.join(fixtures, 'sfz-golden.json')));
const sf2Golden = JSON.parse(read(path.join(fixtures, 'sf2-golden.json')));

// 素の realm。ホストは乱数（取り込みの id を決まった値にする）と、速くするための SHA-256 だけ差し込む
function realm() {
    const context = vm.createContext({});
    context.__et = {
        random: bytes => fixedRandom(bytes),
        sha256: bytes => crypto.createHash('sha256').update(bytes).digest(),
    };
    // V8 のコンテキストは console を持っているが、JavaScriptCore の素のコンテキストは持たない
    vm.runInContext('delete globalThis.console', context);
    vm.runInContext(read(path.join(resources, 'effetune-sfz-prelude.js')), context);
    vm.runInContext(read(path.join(resources, 'effetune-sfz.js')), context);
    const run = code => vm.runInContext(code, context);
    return { context, run, api: run('ETSFZ'), ctx: { U8: run('Uint8Array'), F32: run('Float32Array'), F64: run('Float64Array'), Blob: run('Blob'), File: run('File') } };
}

// 音のファイル（audio）は名前からバイト列へ
const audio = Object.fromEntries(Object.entries(golden.audio).map(([name, text]) => [name, fromB64(text)]));

const sections = ['parser', 'bank', 'badBanks', 'asset', 'imports', 'streamedImports', 'migration', 'normalize'];

for (const section of sections) {
    test(`見本 ${section}: 束ねの答えが上流の答えと同じ`, async t => {
        const r = realm();
        for (const item of golden[section]) {
            await t.test(item.name ?? item.input ?? item.selectedPath, async () => {
                const actual = await expectedFor(section, r.api, r.ctx, item, audio, {});
                assert.deepStrictEqual(actual, item.expected);
            });
        }
    });
}

test('見本 budget', async () => {
    const r = realm();
    for (const item of golden.budget.cases) {
        assert.deepStrictEqual(await expectedFor('budget', r.api, r.ctx, item, audio, { budget: golden.budget }), item.expected, `maxBytes ${item.maxBytes}`);
    }
});

test('見本 folder・merged', async () => {
    const r = realm();
    assert.deepStrictEqual(await expectedFor('folder', r.api, r.ctx, golden.folder, audio, {}), golden.folder.expected);
    assert.deepStrictEqual(JSON.parse(JSON.stringify(r.api.mergeSfzWarnings([{ code: 'invalid-regions', count: 2 }, { code: 'reduced-bank', count: 1 }],
        [{ code: 'invalid-regions', count: 5 }], undefined, [{ code: 'loop-points-ignored', count: 1 }]))), golden.merged);
    assert.deepStrictEqual(JSON.parse(JSON.stringify(r.api.SFZ_REGION_FIELDS)), golden.regionFields);
});

test('見本 SoundFont: 束ねの答えが上流の答えと同じ', async t => {
    const r = realm();
    for (const item of sf2Golden.cases) {
        await t.test(item.name, async () => assert.deepStrictEqual(await runSf2Case(r.api, r.ctx, item), item.expected));
    }
});

// ---- PCM の書き手を差し込んだ道 ----

// 標本ごとに 1 回（path, 浮動小数の位置, フレーム数, チャンネル数, 各チャンネルの面）。ホストは staging の同じ位置へ書く。
// 参照の書き手は、その位置へ 1 浮動小数ずつ（インターリーブ）書く
function withPoolWriter(r) {
    let writes = [], calls = 0;
    r.context.__effectdeckSfzPoolWriter = (...args) => { calls++; writes.push(args); };
    const fill = payload => {
        const pool = new r.ctx.F32(payload, 32);
        for (const [, offset, frames, channels, planes] of writes)
            for (let frame = 0; frame < frames; frame++) for (let c = 0; c < channels; c++) pool[offset + frame * channels + c] = planes[c][frame];
        writes = [];
    };
    return { ctx: { ...r.ctx, onPayload: fill, skipReopen: true }, writes: () => writes, calls: () => calls };
}

for (const section of ['asset', 'imports']) {
    test(`PCM の書き手を差し込んだ道（${section}）: 参照の書き手で埋めると、差し込まない道と同じバイト`, async t => {
        const r = realm();
        const patched = withPoolWriter(r);
        let compared = 0;
        for (const item of golden[section]) {
            const expected = section === 'asset' ? item.expected : item.expected.prepared;
            if (!expected || expected.error) continue;
            await t.test(item.name, async () => {
                const actual = await expectedFor(section, r.api, patched.ctx, item, audio, {});
                const payload = section === 'asset' ? actual.payload : actual.prepared.payload;
                assert.deepStrictEqual(payload, expected.payload);
                compared++;
            });
        }
        assert.ok(compared > 0);
        // 書き手が実際に使われたこと（使われないと、差し込まない道と同じで、何も見ていないのに通ってしまう）
        assert.ok(patched.calls() >= compared, `書き手の呼びが少ない: ${patched.calls()} < ${compared}`);
        assert.equal(patched.writes().length, 0, '書き手の呼びは全部埋めに使われた');
    });
}

test('PCM の書き手は、書き手が無いときの面とは違う（差し込んだ道は JS で複写しない）', async () => {
    const r = realm();
    const patched = withPoolWriter(r);
    const item = golden.asset.find(entry => entry.name === 'two-samples');
    let before;
    const actual = await expectedFor('asset', r.api, { ...r.ctx, onPayload: payload => { before = Buffer.from(payload).toString('base64'); } }, item, audio, {});
    // 上の実行は書き手が差し込まれたまま（書き込みは空振り）。面が空なので、見本の payload とは違う
    assert.notEqual(before, item.expected.payload.b64);
    assert.equal(actual.payload.b64, before);
    assert.ok(patched.writes().length >= 2);
});
