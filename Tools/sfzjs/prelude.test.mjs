// Tools/sfzjs/prelude.test.mjs
// prelude.js を素のコンテキスト（vm.createContext({})）で評価し、Node の標準と突き合わせる。
// 続けて、置いてある束ね（Resources/SFZ/effetune-sfz.js）がプレリュードだけで評価できること、
// 版の印が中身と合っていること、PCM の書き手を差し込む道が素の道と同じバイトを出すことを見る。
//
//   node --test Tools/sfzjs/prelude.test.mjs
//
// 束ねの作り直しは build.mjs（esbuild が要る）の仕事で、ここでは作らない。

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import vm from 'node:vm';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const read = file => fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
const preludeText = read(path.join(here, 'prelude.js'));
// 別の realm の配列・オブジェクトを、deepEqual できる素の値へ
const plain = value => JSON.parse(JSON.stringify(value));
const resources = path.join(repo, 'Sources', 'EffeTuneLive', 'Resources', 'SFZ');

// 素のコンテキスト。host は __et に入れる（無ければ入れない）
function realm(host) {
  const context = vm.createContext({});
  if (host) context.__et = host;
  // V8 のコンテキストは console を持っているが、JavaScriptCore の素のコンテキストは持たない
  vm.runInContext('delete globalThis.console', context);
  vm.runInContext(preludeText, context);
  return { context, run: code => vm.runInContext(code, context) };
}
// コンテキストの中で作った Uint8Array（別の realm の配列だと上流の instanceof が落ちる）
const bytesIn = (r, array) => r.run('Uint8Array').from(array);

test('プレリュードは、無いグローバルだけを入れる', () => {
  const r = realm();
  for (const name of ['TextEncoder', 'TextDecoder', 'crypto', 'Blob', 'File', 'setTimeout', 'clearTimeout', 'console', 'MessageChannel', 'AudioDecoder'])
    assert.notEqual(r.run(`typeof ${name}`), 'undefined', name);
  // 入れてはいけないもの（上流は typeof Worker で道を分ける。無いものは ReferenceError で落ちてほしい）
  for (const name of ['Worker', 'window', 'document', 'fetch', 'navigator', 'EncodedAudioChunk'])
    assert.equal(r.run(`typeof ${name}`), 'undefined', name);
  // 既にあるものは触らない
  const context = vm.createContext({ TextDecoder: class Mine {}, console: { mine: true } });
  vm.runInContext(preludeText, context);
  assert.equal(vm.runInContext('TextDecoder.name', context), 'Mine');
  assert.equal(vm.runInContext('console.mine', context), true);
});

test('UTF-8 の復号は Node と同じ（不正な並び・BOM・fatal）', () => {
  const r = realm();
  const mine = r.run('new TextDecoder("utf-8")'), mineIgnore = r.run('new TextDecoder("utf-8", { ignoreBOM: true })');
  const fatal = r.run('new TextDecoder("utf-8", { fatal: true })');
  const node = new TextDecoder('utf-8'), nodeIgnore = new TextDecoder('utf-8', { ignoreBOM: true });
  const cases = [[], [0x41], [0xEF, 0xBB, 0xBF, 0x41], [0xEF, 0xBB, 0xBF], [0xC0, 0x80], [0xC1, 0xBF], [0xE0, 0x80, 0x80], [0xE0, 0xA0, 0x80],
    [0xED, 0xA0, 0x80], [0xED, 0x9F, 0xBF], [0xF0, 0x80, 0x80, 0x80], [0xF0, 0x90, 0x80, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xF4, 0x8F, 0xBF, 0xBF],
    [0xF5, 0x80], [0xFF], [0x80], [0xBF], [0xE3, 0x81], [0xE3, 0x81, 0x41], [0xF0, 0x9F, 0x98], [0xF0, 0x9F, 0x98, 0x80, 0x80]];
  let seed = 12345;
  const next = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 0x100000000;
  for (let i = 0; i < 4000; i++) cases.push(Array.from({ length: Math.floor(next() * 12) }, () => [0x41, 0x7F, 0x80, 0xBF, 0xC2, 0xDF, 0xE0, 0xED, 0xEF, 0xF0, 0xF4, 0xF5, 0xFF, Math.floor(next() * 256)][Math.floor(next() * 14)]));
  for (const bytes of cases) {
    const input = bytesIn(r, bytes), expected = node.decode(Uint8Array.from(bytes));
    assert.equal(mine.decode(input), expected, bytes.map(b => b.toString(16)).join(' '));
    assert.equal(mineIgnore.decode(input), nodeIgnore.decode(Uint8Array.from(bytes)));
    let nodeThrew = false;
    try { new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(bytes)); } catch { nodeThrew = true; }
    let mineThrew = false;
    try { fatal.decode(input); } catch (error) { mineThrew = error instanceof r.run('TypeError'); }
    assert.equal(mineThrew, nodeThrew, `fatal ${bytes.map(b => b.toString(16)).join(' ')}`);
  }
  // 大きな ASCII と、ArrayBuffer・DataView も受ける
  const big = Buffer.alloc(100000, 0x61);
  assert.equal(mine.decode(bytesIn(r, big)).length, 100000);
  assert.equal(mine.decode(bytesIn(r, [0x61, 0x62]).buffer), 'ab');
  assert.equal(r.run('new TextDecoder().encoding'), 'utf-8');
  assert.throws(() => r.run('new TextDecoder("shift_jis")'), /not supported/);
  assert.throws(() => r.run('new TextDecoder().decode(new Uint8Array(1), { stream: true })'), /stream/);
});

test('windows-1252 は WHATWG の表（256 byte すべて Node と同じ）', () => {
  const r = realm();
  const all = Uint8Array.from({ length: 256 }, (_, i) => i);
  // Node は windows-1252 を ISO-8859-1 として復号する（0x80-0x9F が C1 制御字のまま。WHATWG の表と違う）。
  // 表の 0x80-0x9F は WHATWG の仕様どおりをここに書き、残りは Node と突き合わせる
  const nodeText = new TextDecoder('windows-1252').decode(all);
  const high = '\u20ac\u0081\u201a\u0192\u201e\u2026\u2020\u2021\u02c6\u2030\u0160\u2039\u0152\u008d\u017d\u008f\u0090\u2018\u2019\u201c\u201d\u2022\u2013\u2014\u02dc\u2122\u0161\u203a\u0153\u009d\u017e\u0178';
  const expected = nodeText.slice(0, 0x80) + high + nodeText.slice(0xA0);
  assert.equal(r.run('new TextDecoder("windows-1252")').decode(bytesIn(r, all)), expected);
  for (const label of ['latin1', 'ISO-8859-1', ' us-ascii ', 'cp1252'])
    assert.equal(r.run(`new TextDecoder(${JSON.stringify(label)}).encoding`), 'windows-1252');
  assert.equal(expected.charCodeAt(0x81), 0x81);
  assert.equal(expected.charCodeAt(0x80), 0x20AC);
  assert.equal(high.length, 32);
});

test('TextEncoder は Node と同じ（対にならないサロゲート・encodeInto の打ち切り）', () => {
  const r = realm();
  const encoder = r.run('new TextEncoder()'), node = new TextEncoder();
  const samples = ['', 'abc', 'あいう', '𠮷野家', 'a\ud800b', '\udc00', '\ud83d\ude00\ud83d', '\u00e9\u0000\u07ff\u0800\uffff'];
  for (const text of samples) assert.deepEqual([...encoder.encode(text)], [...node.encode(text)], JSON.stringify(text));
  for (const text of samples) for (const size of [0, 1, 2, 3, 4, 5, 8, 64]) {
    const mine = bytesIn(r, new Array(size).fill(0)), theirs = new Uint8Array(size);
    const a = encoder.encodeInto(text, mine), b = node.encodeInto(text, theirs);
    assert.deepEqual({ read: a.read, written: a.written }, b, `${JSON.stringify(text)} ${size}`);
    assert.deepEqual([...mine], [...theirs]);
  }
  assert.ok(encoder.encode('x') instanceof r.run('Uint8Array'));
});

test('crypto.subtle.digest は Node の SHA-256 と同じ（JS 実装も、ホストの差し込みも）', async () => {
  const lengths = [...Array.from({ length: 140 }, (_, i) => i), 1000, 4096, 65537];
  const sample = n => Buffer.from(Array.from({ length: n }, (_, i) => (i * 31 + 7) & 255));
  for (const host of [undefined, { sha256: bytes => new Uint8Array(crypto.createHash('sha256').update(bytes).digest()) }]) {
    const r = realm(host);
    for (const n of lengths) {
      const result = await r.run('(data) => crypto.subtle.digest("SHA-256", data)')(bytesIn(r, sample(n)));
      assert.equal(Buffer.from(result).toString('hex'), crypto.createHash('sha256').update(sample(n)).digest('hex'), `${host ? 'host' : 'js'} ${n}`);
      assert.ok(result instanceof r.run('ArrayBuffer'));
    }
    // 部分ビュー（byteOffset がある）と ArrayBuffer
    const whole = bytesIn(r, sample(100));
    const part = await r.run('(data) => crypto.subtle.digest("sha-256", data.subarray(10, 60))')(whole);
    assert.equal(Buffer.from(part).toString('hex'), crypto.createHash('sha256').update(sample(100).subarray(10, 60)).digest('hex'));
    await assert.rejects(r.run('(data) => crypto.subtle.digest("SHA-1", data)')(whole), /Unrecognized algorithm/);
  }
});

test('getRandomValues はホストの乱数で埋める', () => {
  const calls = [];
  const r = realm({ random: bytes => { calls.push(bytes.length); bytes.fill(7); } });
  const out = r.run('(() => { const a = new Uint32Array(4); crypto.getRandomValues(a); return a; })()');
  assert.deepEqual([...out], new Array(4).fill(0x07070707));
  assert.deepEqual(calls, [16]);
  assert.throws(() => r.run('crypto.getRandomValues(new Float32Array(1))'));
  assert.throws(() => r.run('crypto.getRandomValues(new Uint8Array(65537))'));
  // ホスト無しのテスト用の代わり
  assert.equal(realm().run('crypto.getRandomValues(new Uint8Array(24)).length'), 24);
});

test('Blob と File: 部品・slice・ホストのファイルの範囲（読むのは arrayBuffer のときだけ）', async () => {
  const reads = [];
  const store = Buffer.from(Array.from({ length: 1000 }, (_, i) => i & 255));
  const r = realm({ readRange: (handle, offset, length) => { reads.push([handle, offset, length]); return new Uint8Array(store.subarray(offset, offset + length)).buffer; } });
  const blob = r.run('new Blob([new Uint8Array([1, 2, 3]), "あ", new ArrayBuffer(2), new Uint16Array([0x0504]).subarray(0)], { type: "Text/Plain" })');
  assert.equal(blob.size, 3 + 3 + 2 + 2);
  assert.equal(blob.type, 'text/plain');
  assert.deepEqual([...new Uint8Array(await blob.arrayBuffer())], [1, 2, 3, 0xE3, 0x81, 0x82, 0, 0, 4, 5]);
  assert.equal(await r.run('(b) => b.slice(-2).arrayBuffer().then(x => x.byteLength)')(blob), 2);
  assert.equal(await blob.slice(3, 6).text(), 'あ');
  // 呼び出し元が後で書き換えても、Blob は作ったときの中身
  const mutable = bytesIn(r, [9, 9]);
  const snap = r.run('(a) => new Blob([a])')(mutable);
  mutable[0] = 0;
  assert.deepEqual([...new Uint8Array(await snap.arrayBuffer())], [9, 9]);

  const file = r.run('__etShim.hostFile')({ handle: 'H', size: 1000, name: 'a.wav', lastModified: 5, webkitRelativePath: 'dir/a.wav' });
  assert.equal(file.name, 'a.wav'); assert.equal(file.lastModified, 5); assert.equal(file.webkitRelativePath, 'dir/a.wav'); assert.equal(file.size, 1000);
  assert.ok(r.run('(f) => f instanceof Blob && f instanceof File')(file));
  const slice = file.slice(100, 164), nested = slice.slice(10, 20);
  assert.equal(reads.length, 0, 'slice は読まない');
  assert.deepEqual([...new Uint8Array(await nested.arrayBuffer())], [...store.subarray(110, 120)]);
  assert.deepEqual(reads, [['H', 110, 10]]);
  // Blob の部品に混ぜた範囲は、書き出す側へ {handle, offset, length} のまま渡る
  const mixed = r.run('(f, range) => new Blob([new Uint8Array([1]), f.slice(5, 9), range])')(file, r.run('__etShim.range')('H', 20, 4));
  assert.deepEqual(plain(r.run('__etShim.segments')(mixed).map(s => (s.bytes ? ['bytes', s.bytes.length] : [s.handle, s.offset, s.length]))), [['bytes', 1], ['H', 5, 4], ['H', 20, 4]]);
  assert.equal(mixed.size, 9);
  assert.equal(reads.length, 1);
  // 空のファイル
  assert.equal(r.run('__etShim.hostFile')({ handle: 'E', size: 0, name: 'e' }).size, 0);
  // ホスト無しでも、handle が配列ならそこから切り出す（テスト用）
  const bareRealm = realm();
  const bare = bareRealm.run('__etShim.hostFile')({ handle: bytesIn(bareRealm, [1, 2, 3, 4, 5]), size: 5, name: 'b' });
  assert.deepEqual([...new Uint8Array(await bare.slice(1, 4).arrayBuffer())], [2, 3, 4]);
  // 読めなかった範囲は黙って返さない
  const broken = realm({ readRange: () => new ArrayBuffer(1) });
  await assert.rejects(broken.run('__etShim.hostFile')({ handle: 'X', size: 4, name: 'x' }).arrayBuffer(), /could not be read/);
});

test('MessageChannel は組の相手へ順にマイクロタスクで渡す（Worker 風の onmessage と terminate）', async () => {
  const r = realm();
  r.run(`globalThis.log = []; globalThis.pair = new MessageChannel();
    pair.port1.onmessage = ({ data }) => { log.push(['one', data]); if (data < 3) pair.port1.postMessage(data + 10); };
    pair.port2.onmessage = ({ data }) => { log.push(['two', data]); };`);
  r.run('pair.port2.postMessage(1); pair.port2.postMessage(2); log.push(["sync"])');
  assert.deepEqual(plain(r.run('log')), [['sync']], '渡るのはマイクロタスクの後');
  await Promise.resolve(); await Promise.resolve(); await Promise.resolve();
  assert.deepEqual(plain(r.run('log')), [['sync'], ['one', 1], ['one', 2], ['two', 11], ['two', 12]]);
  // 先に送った分は、onmessage を付けるまで待つ
  r.run(`globalThis.late = []; globalThis.p = new MessageChannel(); p.port1.postMessage("early");`);
  await Promise.resolve();
  assert.deepEqual(plain(r.run('late')), []);
  r.run('p.port2.onmessage = ({ data }) => late.push(data)');
  await Promise.resolve();
  assert.deepEqual(plain(r.run('late')), ['early']);
  // terminate 後は届かない。ハンドラが投げても他へ波及しない
  r.run('globalThis.n = 0; globalThis.q = new MessageChannel(); q.port2.onmessage = () => { n++; throw new Error("boom"); }; q.port1.postMessage(1); q.port1.postMessage(2);');
  await Promise.resolve();
  assert.equal(r.run('n'), 2);
  r.run('q.port2.terminate(); q.port1.postMessage(3)');
  await Promise.resolve();
  assert.equal(r.run('n'), 2);
});

test('setTimeout はホストのタイマーを使い、clearTimeout で取り消せる', async () => {
  const scheduled = [], cancelled = [];
  const r = realm({ timer: (callback, ms) => { scheduled.push({ callback, ms }); return scheduled.length * 100; }, cancelTimer: id => cancelled.push(id) });
  r.run('globalThis.hits = []; setTimeout((a, b) => hits.push([a, b]), 25, "x", "y"); globalThis.t2 = setTimeout(() => hits.push("no"), 0); clearTimeout(t2); setTimeout(() => hits.push("last"), -5);');
  assert.deepEqual(scheduled.map(s => s.ms), [25, 0, 0]);
  assert.deepEqual(cancelled, [200]);
  for (const s of scheduled) s.callback();
  assert.deepEqual(plain(r.run('hits')), [['x', 'y'], 'last']);
  // ホスト無しは、マイクロタスクで 1 回
  const bare = realm();
  bare.run('globalThis.hit = 0; setTimeout(() => hit++, 1000); const id = setTimeout(() => hit += 10, 0); clearTimeout(id);');
  await Promise.resolve(); await Promise.resolve();
  assert.equal(bare.run('hit'), 1);
});

test('console はホストの log へ、無ければ捨てる', () => {
  const lines = [];
  const r = realm({ log: (level, text) => lines.push([level, text]) });
  r.run('console.warn("a", 1, { b: 2 }, new Error("e").message); console.error("x")');
  assert.deepEqual(lines, [['warn', 'a 1 {"b":2} e'], ['error', 'x']]);
  realm().run('console.log("nothing")');
});

test('AudioDecoder は「圧縮 SoundFont は非対応」と答える入口だけ', async () => {
  const r = realm();
  assert.equal(r.run('typeof AudioDecoder'), 'function');
  assert.deepEqual(plain(await r.run('AudioDecoder.isConfigSupported({ codec: "vorbis" })')), { supported: false });
});

// ---------------------------------------------------------------- 束ね
const bundleText = fs.readFileSync(path.join(resources, 'effetune-sfz.js'), 'utf8');

test('束ねの先頭の印が中身と合い、プレリュードの写しが元と同じ', () => {
  const lines = bundleText.split('\n');
  assert.match(lines[1], /^\/\/ pin: [0-9a-f]{40}$/);
  assert.match(lines[2], /^\/\/ esbuild: 0\.28\.2$/);
  assert.match(lines[3], /^\/\/ patch: effetune-js-sfz-pool-writer\.diff sha256=[0-9a-f]{64}$/);
  const claimed = /^\/\/ sha256: ([0-9a-f]{64})$/.exec(lines[4])[1];
  assert.equal(crypto.createHash('sha256').update(lines.slice(5).join('\n')).digest('hex'), claimed);
  assert.equal(lines[3].split('sha256=')[1], crypto.createHash('sha256').update(read(path.join(repo, 'Patches', 'effetune-js-sfz-pool-writer.diff'))).digest('hex'));
  assert.equal(read(path.join(resources, 'effetune-sfz-prelude.js')), preludeText);
});

function bundled(host) {
  const r = realm(host);
  r.run(bundleText);
  return r;
}

test('束ねは、プレリュードだけの素のコンテキストで評価でき、決めた名前だけを出す', () => {
  const r = bundled();
  const names = Object.keys(r.run('ETSFZ')).sort();
  assert.deepEqual(names, ['SFZ_REGION_FIELDS', 'SfzLibraryService', 'attachSfzSampleStreamWorker', 'compileSf2', 'decodeSfzBank', 'encodeSfzBank',
    'identifySfzBank', 'listSfzFolderFiles', 'mergeSfzWarnings', 'normalizeSfzPath', 'openSf2Source', 'packSf2Modulation', 'packSfzAsset', 'packStreamedSfzAsset',
    'parseSf2', 'parseSfz', 'prepareSfzSamples', 'prepareSoundFontBank', 'prepareStreamedSfzBank', 'samplePlayerPreparationData', 'selectSfzRegionsForBudget',
    'sf2SamplerRegions', 'sfzPluginPreparationContext', 'sfzPreparationContext'].sort());
  // Worker 道を見に行かない（typeof Worker は undefined のまま）
  assert.equal(r.run('typeof Worker'), 'undefined');
  assert.ok(read(path.join(here, 'modules.txt')).split('\n').filter(Boolean).length > 40);
});

// 最小の WAV（16bit モノ 48kHz）。parseIrAudioHeader が読めればよい
const wavFile = frames => {
  const b = Buffer.alloc(44 + frames * 2);
  b.write('RIFF', 0); b.writeUInt32LE(36 + frames * 2, 4); b.write('WAVEfmt ', 8); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(48000, 24); b.writeUInt32LE(96000, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write('data', 36); b.writeUInt32LE(frames * 2, 40);
  return b;
};

async function pack(r, { poolWriter }) {
  const text = '<global> ampeg_release=0.5\n<group> cutoff=1200 fil_type=lpf_2p\n<region> sample=a.wav key=60 lfo1_freq=4 lfo1_pitch=20\n<region> sample=*sine key=62\n<region> sample=*noise key=64';
  const parsed = await r.run('ETSFZ').parseSfz({ selectedPath: 'i.sfz', readText: async f => (f === 'i.sfz' ? text : null), hasSample: f => f === 'a.wav', onDiagnostic: () => {} });
  const F32 = r.run('Float32Array'), U8 = r.run('Uint8Array');
  const pcm = { sampleRate: 48000, channels: [F32.from({ length: 4800 }, (_, i) => Math.sin(i / 10))] };
  const writes = [];
  if (poolWriter) r.context.__effectdeckSfzPoolWriter = (...args) => writes.push(args);
  const prepared = await r.run('ETSFZ').prepareSfzSamples(parsed, async () => U8.from(wavFile(4800)), async () => pcm, 1 << 28, () => {});
  delete r.context.__effectdeckSfzPoolWriter;
  return { prepared, writes };
}

test('束ねを通した準備: 素の道と、PCM の書き手を差し込む道は、書き手が埋めた後で同じバイト', async () => {
  const direct = await pack(bundled(), { poolWriter: false });
  const patched = await pack(bundled(), { poolWriter: true });
  const a = Buffer.from(direct.prepared.descriptor.payload), b = Buffer.from(patched.prepared.descriptor.payload);
  assert.equal(a.readUInt32LE(0), 0x31415445);
  assert.equal(a.length, b.length);
  // 書き手は標本ごとに 1 回。(path, 浮動小数の位置, フレーム数, チャンネル数, 各チャンネルの平面)。
  // generator（*sine・*noise は *prepared-cycle:N になる）の PCM は JS の中にしか無いので、平面も一緒に渡る
  assert.deepEqual(patched.writes.map(w => [w[0], w[2], w[3]]), [['*prepared-cycle:0', 4095, 1], ['*prepared-cycle:1', 3, 1], ['a.wav', 4800, 1]]);
  assert.equal(direct.writes.length, 0);
  assert.ok(!a.equals(b), '差し込んだ道は PCM を JS では複写しない');
  // 参照の書き手（ホストが staging へやることの JS 版）で埋めると同じになる
  const pool = new Float32Array(b.buffer, b.byteOffset + 32, (b.length - 32) / 4);
  for (const [, offset, frames, channels, planes] of patched.writes)
    for (let frame = 0; frame < frames; frame++) for (let c = 0; c < channels; c++) pool[offset + frame * channels + c] = planes[c][frame];
  assert.ok(a.equals(b));
});

// フォルダの取り込み（id は内容の SHA-256）。ホストの File の形（__etShim.hostFile）で、上流の素の実行と同じ id・同じバイト
test('束ねを通した取り込み: ホストのファイルでも、上流を Node で直に動かした結果と同じ id', async () => {
  const wav = wavFile(600);
  for (let i = 0; i < 600; i++) wav.writeInt16LE((i * 37 % 2000) - 1000, 44 + i * 2);
  const sfz = Buffer.from('<region> sample=a.wav key=60 cutoff=900\n<region> sample=missing.wav key=61');
  const runWith = async (service, makeFile, makeFloats) => {
    const store = new Map();
    const backend = { async cleanupTemporary() {}, async read(name) { return store.get(name) ?? null; }, async writeAtomic(name, bytes) { store.set(name, bytes); },
      async remove(name) { store.delete(name); } };
    const library = await new service.SfzLibraryService(backend, { onDiagnostic() {}, getMaxBytes: () => 256 << 20 }).open();
    const decode = async buffer => {
      const view = new DataView(buffer), count = view.getUint32(40, true) / 2, plane = makeFloats(count);
      for (let i = 0; i < count; i++) plane[i] = view.getInt16(44 + 2 * i, true) / 32768;
      return { sampleRate: 48000, channels: [plane] };
    };
    const entry = await library.importFolderFiles([makeFile('i.sfz', sfz), makeFile('a.wav', wav)], 'i.sfz', { decode });
    return { id: entry.id, size: entry.size, payload: Buffer.from(library.prepared.value.descriptor.payload).toString('base64') };
  };
  const r = bundled();
  const hostFile = r.run('__etShim.hostFile');
  const viaBundle = await runWith(r.run('ETSFZ'),
    (name, bytes) => hostFile({ handle: r.run('Uint8Array').from(bytes), size: bytes.length, name, lastModified: 0, webkitRelativePath: `inst/${name}` }),
    count => new (r.run('Float32Array'))(count));
  assert.match(viaBundle.id, /^[0-9a-f]{24}$/);

  const upstream = path.join(process.env.EFFETUNE_ROOT || path.join(repo, 'Vendor', 'effetune'), 'js', 'sfz', 'service.js');
  if (!fs.existsSync(upstream)) return;
  const direct = await import(pathToFileURL(upstream).href);
  const viaNode = await runWith(direct, (name, bytes) => ({ name, size: bytes.length, lastModified: 0, webkitRelativePath: `inst/${name}`,
    async arrayBuffer() { return Uint8Array.from(bytes).buffer; }, slice(from, to) { return new Blob([bytes.subarray(from, to)]); } }), count => new Float32Array(count));
  assert.deepEqual(viaBundle, viaNode);
});
