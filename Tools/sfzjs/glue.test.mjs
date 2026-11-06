// Tools/sfzjs/glue.test.mjs
// Swift（DSP/SFZScript/ETSFZScriptService.swift）が文脈に入れる「つなぎの JS」（glue）を、置いてある束ねと並べて素の realm
// （vm）で走らせ、SoundFont（SF2）の取り込み → 読み直し（prepare）が上流のとおりに通ることを見る。
// ホストの口（__et）は Node のファイルで作り替える（Swift の ETSFZScriptEnvironment が受け持つ 6 つの置き場の操作・範囲の読み・
// 受け渡し・見積り）。JavaScriptCore そのものは通らないが、glue と束ねと上流の service の組み合わせは同じ。
//
//   node --test Tools/sfzjs/glue.test.mjs
//
// 見ること:
//   - 一覧（listInstruments）に SF2 が出る
//   - importFolder が SF2 を .sfzbank に書き、index.json に format: "sf2" と streamedSource: true を残す
//   - prepare が v9 の payload（制御の部分 = payload 全体）と、Preset の一覧・標本の置き場所を返す
//   - 標本の置き場所が正しい: .sfzbank の base + dataOffset から読むと SF2 の smpl と同じバイト、
//     並びは payload の標本の表（frames・sampleRate）と同じ

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { decodeWav, fixedRandom, fromB64 } from '../golden/sfz_runner.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const read = file => fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
const resources = path.join(repo, 'Sources', 'EffeTuneLive', 'Resources', 'SFZ');
const sf2Golden = JSON.parse(read(path.join(repo, 'Tests', 'Fixtures', 'SFZ', 'sf2-golden.json')));
const sfzGolden = JSON.parse(read(path.join(repo, 'Tests', 'Fixtures', 'SFZ', 'sfz-golden.json')));

// Swift の raw 文字列（#""" … """#）から glue を取り出す。閉じの字下げ（4 桁）は Swift が外す
function glueSource() {
    const text = read(path.join(repo, 'Sources', 'EffeTuneLive', 'DSP', 'SFZScript', 'ETSFZScriptService.swift'));
    const start = text.indexOf('static let glue = #"""\n');
    assert.ok(start >= 0, 'glue の始まりが見つからない');
    const body = text.slice(start + 'static let glue = #"""\n'.length);
    const end = body.indexOf('\n    """#');
    assert.ok(end >= 0, 'glue の終わりが見つからない');
    return body.slice(0, end).split('\n').map(line => line.startsWith('    ') ? line.slice(4) : line).join('\n');
}

function makeHost(root, context) {
    const U8 = vm.runInContext('Uint8Array', context), F32 = vm.runInContext('Float32Array', context);
    const handles = new Map();
    let next = 1;
    const register = file => { const handle = next++; handles.set(handle, file); return handle; };
    const delivered = {};
    const estimates = [];
    const readFrom = (handle, offset, length) => {
        const fd = fs.openSync(handles.get(handle), 'r');
        try {
            const buffer = Buffer.alloc(length);
            assert.equal(fs.readSync(fd, buffer, 0, length, offset), length);
            return U8.from(buffer);
        } finally { fs.closeSync(fd); }
    };
    const keyPath = key => path.join(root, key);
    const host = {
        random: bytes => fixedRandom(bytes),
        sha256: bytes => crypto.createHash('sha256').update(bytes).digest(),
        readRange: (handle, offset, length) => readFrom(handle, offset, length),
        isCurrent: () => true,
        log: () => {},
        deliver: (name, bytes) => { delivered[name] = Buffer.from(new Uint8Array(bytes.buffer ?? bytes, bytes.byteOffset ?? 0, bytes.byteLength)); },
        // SoundFont は decode を通らない。SFZ の標本は 16 bit の WAV（見本の読みと同じ）
        decode: bytes => decodeWav(new Uint8Array(bytes.buffer ?? bytes, bytes.byteOffset ?? 0, bytes.byteLength), F32),
        estimate: (control, payloadBytes, sampleRate, channels, maxFrames, bpm, kind, formatTag) => {
            estimates.push({ controlBytes: control.byteLength, payloadBytes, sampleRate, channels, maxFrames, bpm, kind, formatTag });
            return 8 * 1024 * 1024;
        },
        backend: {
            cleanupTemporary() {},
            read: key => fs.existsSync(keyPath(key)) ? U8.from(fs.readFileSync(keyPath(key))) : null,
            writeAtomic: (key, bytes) => { fs.writeFileSync(keyPath(key), Buffer.from(bytes)); },
            remove: key => { fs.rmSync(keyPath(key), { force: true }); },
            openFile: name => {
                const file = keyPath(name);
                if (!fs.existsSync(file)) return null;
                return { handle: register(file), size: fs.statSync(file).size, name, lastModified: 0 };
            },
            writeFile: (name, segments) => {
                const parts = [];
                for (const segment of segments) {
                    if (segment.bytes) parts.push(Buffer.from(segment.bytes));
                    else parts.push(Buffer.from(readFrom(segment.handle, segment.offset, segment.length)));
                }
                fs.writeFileSync(keyPath(name), Buffer.concat(parts));
            },
        },
    };
    return { host, register, delivered, estimates };
}

function realm(root) {
    const context = vm.createContext({});
    const made = makeHost(root, context);
    context.__et = made.host;
    vm.runInContext('delete globalThis.console', context);
    vm.runInContext(read(path.join(resources, 'effetune-sfz-prelude.js')), context);
    vm.runInContext(read(path.join(resources, 'effetune-sfz.js')), context);
    vm.runInContext(glueSource(), context);
    const api = vm.runInContext('__etSfz', context);
    api.configure(256 * 1024 * 1024, false);
    return { context, api, ...made };
}

const geometry = JSON.stringify({ sampleRate: 48000, processingChannels: 2, maxFrames: 4096, minimumPhysicalBpm: 0, playerKind: 0 });
const caseNamed = name => sf2Golden.cases.find(item => item.name === name);

async function importSoundFont(r, root, fixtureName, given = null) {
    const bytes = given ?? Buffer.from(fromB64(caseNamed(fixtureName).fixture));
    const file = path.join(root, '..', `${path.basename(root)}-${fixtureName}.sf2`);
    fs.writeFileSync(file, bytes);
    const list = JSON.stringify([{ handle: r.register(file), size: bytes.length, lastModified: 0, name: 'test.sf2', path: 'Banks/test.sf2' }]);
    return { bytes, list };
}


// 標本が 2 本ある SF2（長さも rate も違う）。標本の番号の並びと置き場所を見るため。上流の tests/helpers/sf2-fixture.mjs と
// 同じ作り（標本の間に 46 点の 0 を置く）を 2 本に広げたもの。キーの範囲は標本ごとに分ける
function twoSampleSoundFont() {
    const text = value => Buffer.from(value, 'ascii');
    const chunk = (name, data) => { const head = Buffer.alloc(8); head.write(name); head.writeUInt32LE(data.length, 4); return Buffer.concat([head, data, Buffer.alloc(data.length % 2)]); };
    const list = (name, children) => chunk('LIST', Buffer.concat([text(name), ...children]));
    const gen = (operator, amount) => { const b = Buffer.alloc(4); b.writeUInt16LE(operator); b.writeUInt16LE(amount & 65535, 2); return b; };
    const bag = (generator, modulator = 0) => gen(generator, modulator);
    const samples = [{ start: 0, frames: 64, rate: 48000 }, { start: 64 + 46, frames: 100, rate: 22050 }];
    const phdr = Buffer.alloc(2 * 38); phdr.write('Preset'); phdr.writeUInt16LE(0, 24); phdr.writeUInt16LE(1, 38 + 24);
    const inst = Buffer.alloc(44); inst.write('Instrument'); inst.writeUInt16LE(0, 20); inst.writeUInt16LE(2, 22 + 20);
    const shdr = Buffer.alloc(3 * 46);
    samples.forEach((sample, index) => {
        const o = index * 46;
        shdr.write(`Sample${index}`, o, 20, 'ascii'); shdr.writeUInt32LE(sample.start, o + 20); shdr.writeUInt32LE(sample.start + sample.frames, o + 24);
        shdr.writeUInt32LE(sample.start + 8, o + 28); shdr.writeUInt32LE(sample.start + sample.frames - 8, o + 32);
        shdr.writeUInt32LE(sample.rate, o + 36); shdr[o + 40] = 60; shdr.writeUInt16LE(1, o + 44);
    });
    const tables = { phdr, pbag: Buffer.concat([bag(0), bag(1)]), pmod: Buffer.alloc(10),
        pgen: Buffer.concat([gen(41, 0), gen(0, 0)]), inst, ibag: Buffer.concat([bag(0), bag(3), bag(6)]), imod: Buffer.alloc(10),
        // キーの範囲は low | high << 8。標本 0 は 0〜47、標本 1 は 48〜127
        igen: Buffer.concat([gen(43, 0 | 47 << 8), gen(54, 1), gen(53, 0), gen(43, 48 | 127 << 8), gen(54, 1), gen(53, 1), gen(0, 0)]), shdr };
    const total = samples[1].start + samples[1].frames + 46;
    const pcm = Buffer.alloc(total * 2);
    for (let frame = 0; frame < total; frame++) pcm.writeInt16LE(((frame * 37) % 2000) - 1000, frame * 2);
    const low = Buffer.alloc(total);
    for (let frame = 0; frame < total; frame++) low[frame] = (frame * 11) & 255;
    return chunk('RIFF', Buffer.concat([text('sfbk'), list('INFO', [chunk('ifil', Buffer.from([2, 0, 4, 0])), chunk('INAM', text('Two\0'))]),
        list('sdta', [chunk('smpl', pcm), chunk('sm24', low)]), list('pdta', Object.entries(tables).map(([name, bytes]) => chunk(name, bytes)))]));
}

function word(buffer, offset) { return buffer.readUInt32LE(offset); }

for (const [fixtureName, given] of [['native-fixture', null], ['collection-16-presets', null], ['two-samples', twoSampleSoundFont()]]) {
    test(`SoundFont（${fixtureName}）: 一覧 → 取り込み → prepare が上流のとおりに通り、標本の置き場所が合う`, async () => {
        const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sfzglue-'));
        try {
            const r = realm(root);
            const { bytes, list } = await importSoundFont(r, root, fixtureName, given);

            // 一覧に SF2 が出る
            assert.deepEqual(JSON.parse(await r.api.listInstruments(list)), ['Banks/test.sf2']);

            // 取り込み: .sfzbank と index.json
            const entry = JSON.parse(await r.api.importFolder(list, 'Banks/test.sf2'));
            assert.equal(entry.format, 'sf2');
            assert.equal(entry.streamedSource, true);
            assert.match(entry.id, /^[0-9a-f]{24}$/);
            assert.ok(entry.regionCount >= 1);
            const index = JSON.parse(fs.readFileSync(path.join(root, 'index.json'), 'utf8'));
            assert.equal(index.entries.length, 1);
            assert.equal(index.entries[0].format, 'sf2');
            assert.equal(index.entries[0].streamedSource, true);
            const bank = fs.readFileSync(path.join(root, `${entry.id}.sfzbank`));

            // 読み直し
            const prepared = JSON.parse(await r.api.prepare(entry.id, geometry));
            assert.equal(prepared.format, 'sf2');
            assert.equal(prepared.tableVersion, 9);
            assert.equal(prepared.regionCount, entry.regionCount);
            const control = r.delivered.control;
            assert.equal(control.length, prepared.payloadBytes, '流し込みの入れ物は制御の部分が payload 全体');
            assert.equal(32 + word(control, 48) * 4, control.length);
            assert.equal(r.estimates.length >= 1, true, '見積りはホストへ聞く');
            for (const estimate of r.estimates) {
                assert.equal(estimate.controlBytes, control.length);
                assert.equal(estimate.sampleRate, 48000);
                assert.equal(estimate.channels, 2);
                assert.equal(estimate.maxFrames, 4096);
                assert.equal(estimate.kind, 0);
            }
            assert.ok(prepared.footprintBytes > prepared.payloadBytes);

            // Preset の一覧
            const soundFont = prepared.soundFont;
            assert.ok(soundFont, 'soundFont がある');
            assert.equal(soundFont.format, 'sf2');
            assert.ok(soundFont.presets.length >= 1);
            for (const preset of soundFont.presets) {
                assert.equal(typeof preset.bank, 'number');
                assert.equal(typeof preset.program, 'number');
                assert.equal(typeof preset.name, 'string');
            }

            // 標本の置き場所: payload の標本の表と同じ並び・同じ値、.sfzbank から読むと SF2 の smpl と同じバイト
            const ints = new Uint32Array(control.buffer.slice(control.byteOffset, control.byteOffset + control.length), 32);
            const tableOffset = ints[12], count = ints[13];
            assert.equal(count, soundFont.samples.length, '標本の数が payload の表と同じ');
            if (fixtureName === 'two-samples') {
                assert.deepEqual(soundFont.samples.map(sample => [sample.frames, sample.sampleRate]), [[64, 48000], [100, 22050]]);
            }
            for (const [number, sample] of soundFont.samples.entries()) {
                const row = tableOffset + number * 12;
                assert.equal(ints[row], sample.frames, `標本 ${number} の frames`);
                assert.equal(ints[row + 1], 0);
                assert.equal(ints[row + 2], 1, 'SF2 の標本は 1 チャンネル');
                assert.equal(ints[row + 3], sample.sampleRate, `標本 ${number} の sampleRate`);
                assert.equal(sample.compressed, false);
                const high = bank.subarray(sample.base + sample.dataOffset, sample.base + sample.dataOffset + sample.frames * 2);
                const original = bytes.subarray(sample.dataOffset, sample.dataOffset + sample.frames * 2);
                assert.equal(high.length, sample.frames * 2);
                assert.ok(high.equals(original), `標本 ${number} の PCM が SF2 のものと同じ`);
                if (sample.lowByteOffset !== null) {
                    assert.ok(bank.subarray(sample.base + sample.lowByteOffset, sample.base + sample.lowByteOffset + sample.frames)
                        .equals(bytes.subarray(sample.lowByteOffset, sample.lowByteOffset + sample.frames)), `標本 ${number} の sm24`);
                }
            }

            // 置き場の一覧にも format が残る
            const listed = JSON.parse(await r.api.list());
            assert.equal(listed.length, 1);
            assert.equal(listed[0].format, 'sf2');
        } finally { fs.rmSync(root, { recursive: true, force: true }); }
    });
}

test('SFZ の prepare には soundFont が付かない（Preset の欄は出さない）', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sfzglue-'));
    try {
        const r = realm(root);
        const item = sfzGolden.imports.find(candidate => candidate.name === 'plain');
        const files = [];
        for (const [name, value] of Object.entries(item.folder)) {
            const file = path.join(root, '..', `${path.basename(root)}-${name.replace(/[\/]/g, '_')}`);
            fs.writeFileSync(file, value.text !== undefined ? Buffer.from(value.text, 'utf8') : Buffer.from(fromB64(value.b64)));
            files.push({ handle: r.register(file), size: fs.statSync(file).size, lastModified: 0,
                name: name.split('/').pop(), path: name });
        }
        const list = JSON.stringify(files);
        assert.deepEqual(JSON.parse(await r.api.listInstruments(list)), ['other.sfz', 'piano.sfz']);
        const entry = JSON.parse(await r.api.importFolder(list, item.selected));
        assert.equal(entry.format, undefined);
        const prepared = JSON.parse(await r.api.prepare(entry.id, geometry));
        assert.equal(prepared.soundFont, null);
        assert.notEqual(prepared.tableVersion, 9);
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
