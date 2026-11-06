// Tools/sfzjs/stream.test.mjs
// 流し込みの SFZ（load_*・予算超え）が、置いてある束ねと glue（DSP/SFZScript/ETSFZScriptService.swift）で、上流の
// prepareStreamedSfzBank のまま取り込み → prepare まで通ることを見る。JavaScriptCore には Worker が無いので、glue は
// 同じ文脈の中の組（inProcessWorker）で上流の sample-stream-worker を動かす。ホストの口は glue_host.mjs（Node のファイル）。
//
//   node --test Tools/sfzjs/stream.test.mjs
//
// 見ること:
//   - load_* を持つ SFZ・効果の IR・発生源（*sine）が、v10 の payload（制御の部分 = payload 全体）と標本の置き場所で返る
//   - 置き場所が正しい: 入れ物（.sfzbank）の offset から size 読むと元の WAV と同じバイト、payload の標本の表と同じ並び
//   - 入れ物の外の標本（発生源）は JS が作ったバイト列を deliver する
//   - 予算を超える常駐のバンクは、取り込みが流し込みに回り、prepare も予算に収まる（以前は too-large）
//   - 常駐のバンク（v6・v7）は今までどおり、流し込みの表を付けない
//   - Tests/Fixtures/SFZ/stream-table-golden.json（Swift の SFZStreamTableTests の見本）が作り直したものと同じ

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fromB64 } from '../golden/sfz_runner.mjs';
import { wav } from '../golden/sfz_cases.mjs';
import { geometryJSON, read, realm, repo, writeFolder } from './glue_host.mjs';
import { build, caseNames, defaultOut } from './stream_table_golden.mjs';

const golden = JSON.parse(read(path.join(repo, 'Tests', 'Fixtures', 'SFZ', 'sfz-golden.json')));
const streamed = name => golden.streamedImports.find(item => item.name === name);
const word = (buffer, index) => buffer.readUInt32LE(32 + index * 4);

async function withBank(item, fn, { maxBytes = item.maxBytes, folder = item.folder, selected = item.selected } = {}) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sfzstream-'));
    try {
        const r = realm(root, { maxBytes });
        const list = writeFolder(r, root, folder, fromB64);
        const entry = JSON.parse(await r.api.importFolder(list, selected));
        const bank = fs.readFileSync(path.join(root, `${entry.id}.sfzbank`));
        return await fn({ r, root, list, entry, bank });
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
}

// payload の標本の表（v10 は 16 語の行）から、標本 1 本ごとの行と resident の範囲を読む（Swift の SFZStreamTable と同じ式を、別に書いたもの）
function table(control) {
    assert.equal(word(control, 1), 10);
    const start = word(control, 12), count = word(control, 13), residentAt = word(control, 17), residentCount = word(control, 18);
    const rows = [];
    for (let sample = 0; sample < count; sample++) {
        const at = start + sample * 16;
        rows.push({ frames: word(control, at) + word(control, at + 1) * 2 ** 32, channels: word(control, at + 2), sampleRate: word(control, at + 3),
            mode: word(control, at + 12), cursor: word(control, at + 13), count: word(control, at + 14) });
    }
    const intervals = [];
    for (let row = 0; row < residentCount; row++) {
        const at = residentAt + row * 4;
        intervals.push([word(control, at) + word(control, at + 1) * 2 ** 32, word(control, at + 2) + word(control, at + 3) * 2 ** 32]);
    }
    return { rows, intervals };
}

function residentPages(control) {
    const { rows, intervals } = table(control);
    const pages = [];
    rows.forEach((row, sample) => {
        for (const [first, end] of intervals.slice(row.cursor, row.cursor + row.count)) {
            for (let page = Math.floor(first / 4096); page <= Math.floor((end - 1) / 4096); page++) pages.push([sample, page]);
        }
    });
    return pages;
}

test('load_* を持つ SFZ: 取り込みは流し込みの入れ物になり、prepare は v10 と標本の置き場所を返す', async () => {
    const item = streamed('streamed-load-opcodes');
    await withBank(item, async ({ r, entry, bank }) => {
        assert.equal(entry.streamedSource, true);
        assert.match(entry.id, /^[0-9a-f]{24}$/);
        const prepared = JSON.parse(await r.api.prepare(entry.id, geometryJSON()));
        assert.equal(prepared.tableVersion, 10);
        assert.equal(prepared.soundFont, null);
        const control = r.delivered.control;
        assert.equal(control.length, prepared.payloadBytes, '流し込みの入れ物は制御の部分が payload 全体');
        assert.equal(32 + word(control, 4) * 4, control.length);
        assert.ok(prepared.footprintBytes > prepared.payloadBytes);
        assert.ok(r.estimates.length >= 1, '見積りはホストへ聞く');
        for (const estimate of r.estimates) assert.equal(estimate.controlBytes, control.length);
        assert.ok(r.reads.length > 0, '標本の頭は host の readRange で読む');

        const { rows } = table(control);
        assert.equal(prepared.streamSamples.length, rows.length);
        // 並びは payload の表と同じ。load_mode=1 の標本は 16 bit の保存形式（mode 1）で別の番号
        assert.deepEqual(prepared.streamSamples.map(sample => sample.mode), [1, 0]);
        for (const [number, sample] of prepared.streamSamples.entries()) {
            assert.equal(sample.index, number);
            assert.equal(sample.frames, rows[number].frames);
            assert.equal(sample.channels, rows[number].channels);
            assert.equal(sample.sampleRate, rows[number].sampleRate);
            assert.equal(sample.mode, rows[number].mode);
            assert.equal(sample.inline, false);
        }
        // 入れ物の中の位置は、元の WAV の位置（a.wav = 標本 0、c.wav = 標本 1）
        const originals = ['a.wav', 'c.wav'].map(name => Buffer.from(fromB64(item.folder[name].b64)));
        prepared.streamSamples.forEach((sample, number) => {
            assert.equal(sample.size, originals[number].length);
            assert.ok(bank.subarray(sample.offset, sample.offset + sample.size).equals(originals[number]), `標本 ${number} のバイト`);
        });
        // load_start=10 load_end=300 は、頭の 1 ページだけを resident にする
        assert.deepEqual(residentPages(control), [[0, 0]]);
    });
});

test('効果の IR は全体が resident、発生源（*sine）は JS のバイト列を渡す', async () => {
    await withBank(streamed('streamed-effects'), async ({ r, entry, bank }) => {
        const prepared = JSON.parse(await r.api.prepare(entry.id, geometryJSON()));
        const control = r.delivered.control;
        assert.deepEqual(prepared.streamSamples.map(sample => [sample.frames, sample.inline]), [[600, false], [64, false]]);
        // ir.wav（64 フレーム）は標本 1。全体 = ページ 0
        assert.deepEqual(residentPages(control), [[1, 0]]);
        const ir = Buffer.from(fromB64(streamed('streamed-effects').folder['ir.wav'].b64));
        assert.ok(bank.subarray(prepared.streamSamples[1].offset, prepared.streamSamples[1].offset + ir.length).equals(ir));
    });
    await withBank(streamed('streamed-generators'), async ({ r, entry }) => {
        const prepared = JSON.parse(await r.api.prepare(entry.id, geometryJSON()));
        const [generated, file] = prepared.streamSamples;
        assert.equal(generated.inline, true);
        assert.equal(generated.offset, null);
        assert.equal(generated.frames, 4095, '*sine の 1 周期');
        const bytes = r.delivered['stream:0'];
        assert.equal(bytes.length, generated.size);
        assert.equal(bytes.subarray(0, 4).toString('latin1'), 'RIFF');
        assert.equal(bytes.readUInt16LE(20), 3, 'IEEE float の WAV');
        assert.equal(file.inline, false);
        assert.equal(r.delivered['stream:1'], undefined, '入れ物の中の標本は渡さない');
        // 周期は全体が resident（4095 フレームはページ 0 だけ）
        assert.deepEqual(residentPages(r.delivered.control), [[0, 0]]);
    });
});

test('予算を超える常駐のバンクは流し込みに回り、prepare も予算に収まる', async () => {
    // 4 本の 300000 フレーム（16 bit のモノ、約 600 KB）。常駐だと 4 本で 4.8 MB（float）要るので、2 MiB の予算を超える
    const files = { 'big.sfz': { text: ['<control> default_path=s/', ...['a', 'b', 'c', 'd'].map((name, index) => `<region> sample=${name}.wav lokey=${36 + index * 12} hikey=${47 + index * 12}`)].join('\n') } };
    ['a', 'b', 'c', 'd'].forEach((name, index) => {
        files[`s/${name}.wav`] = { b64: Buffer.from(wav({ channels: 1, rate: 48000, frames: 300000, seed: index + 1 })).toString('base64') };
    });
    const maxBytes = 2 * 1024 * 1024;
    const options = { maxBytes, folder: files, selected: 'big.sfz' };
    await withBank({}, async ({ r, entry }) => {
        assert.equal(entry.streamedSource, true, '予算を超えるので流し込みの入れ物');
        const prepared = JSON.parse(await r.api.prepare(entry.id, geometryJSON()));
        assert.equal(prepared.tableVersion, 10);
        assert.ok(prepared.footprintBytes <= maxBytes, `予算に収まる: ${prepared.footprintBytes}`);
        assert.equal(prepared.streamSamples.length, 4);
        assert.deepEqual(prepared.streamSamples.map(sample => sample.frames), [300000, 300000, 300000, 300000]);
        // 同じ id をもう 1 度読んでも（上流の cache に頼らず）同じ payload になる
        const first = Buffer.from(r.delivered.control);
        const again = JSON.parse(await r.api.prepare(entry.id, geometryJSON()));
        assert.equal(again.tableVersion, 10);
        assert.ok(r.delivered.control.equals(first));
    }, options);
    // 予算が十分なら、同じバンクは常駐のまま（v7）で、流し込みの表は付かない
    await withBank({}, async ({ r, entry }) => {
        assert.equal(entry.streamedSource, undefined);
        const prepared = JSON.parse(await r.api.prepare(entry.id, geometryJSON()));
        assert.ok([6, 7].includes(prepared.tableVersion), `v${prepared.tableVersion}`);
        assert.equal(prepared.streamSamples, null);
    }, { ...options, maxBytes: 256 * 1024 * 1024 });
});

test('流し込みでも収まらないバンクは too-large で断る', async () => {
    const item = streamed('streamed-too-large-even-streamed');
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sfzstream-'));
    try {
        const r = realm(root, { maxBytes: item.maxBytes });
        const list = writeFolder(r, root, item.folder, fromB64);
        await assert.rejects(() => r.api.importFolder(list, item.selected), error => error.code === 'too-large');
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('常駐のバンク（v6・v7）の prepare は、流し込みの表を付けない', async () => {
    const item = golden.imports.find(candidate => candidate.name === 'plain');
    await withBank(item, async ({ r, entry }) => {
        const prepared = JSON.parse(await r.api.prepare(entry.id, geometryJSON()));
        assert.equal(prepared.tableVersion, 7);
        assert.equal(prepared.streamSamples, null);
        assert.equal(prepared.soundFont, null);
    });
});

test('Swift の見本（stream-table-golden.json）は、今の束ねと glue から作り直したものと同じ', async () => {
    const committed = JSON.parse(read(defaultOut));
    const rebuilt = JSON.parse(JSON.stringify(await build()));
    assert.deepEqual(committed.cases.map(item => item.name), caseNames);
    assert.deepEqual(rebuilt, committed, 'node Tools/sfzjs/stream_table_golden.mjs を回して、コミットする');
});

test('configure の streaming を false にすると、流し込みの道は無く、上流の too-large・needs sample streaming のまま', async () => {
    const item = streamed('streamed-load-opcodes');
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sfzstream-'));
    try {
        const r = realm(root, { maxBytes: item.maxBytes });
        r.api.configure(item.maxBytes, false, false);
        const list = writeFolder(r, root, item.folder, fromB64);
        await assert.rejects(() => r.api.importFolder(list, item.selected), /needs sample streaming/);
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
