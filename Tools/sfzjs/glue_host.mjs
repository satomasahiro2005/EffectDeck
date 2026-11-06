// Tools/sfzjs/glue_host.mjs
// 置いてある束ねと glue（DSP/SFZScript/ETSFZScriptService.swift の raw 文字列）を、素の realm（vm）で走らせる道具。
// ホストの口（__et）は Node のファイルで作り替える（Swift の ETSFZScriptEnvironment が受け持つ置き場の操作・範囲の読み・
// 受け渡し・見積り）。JavaScriptCore そのものは通らないが、glue と束ねと上流の service の組み合わせは同じ。
// stream.test.mjs と stream_table_golden.mjs が使う（glue.test.mjs は自前の写しを持つ）。

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { decodeWav, fixedRandom } from '../golden/sfz_runner.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
export const repo = path.resolve(here, '..', '..');
export const read = file => fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
export const resources = path.join(repo, 'Sources', 'EffeTuneLive', 'Resources', 'SFZ');

// Swift の raw 文字列（#""" … """#）から glue を取り出す。閉じの字下げ（4 桁）は Swift が外す
export function glueSource() {
    const text = read(path.join(repo, 'Sources', 'EffeTuneLive', 'DSP', 'SFZScript', 'ETSFZScriptService.swift'));
    const start = text.indexOf('static let glue = #"""\n');
    assert.ok(start >= 0, 'glue の始まりが見つからない');
    const body = text.slice(start + 'static let glue = #"""\n'.length);
    const end = body.indexOf('\n    """#');
    assert.ok(end >= 0, 'glue の終わりが見つからない');
    return body.slice(0, end).split('\n').map(line => line.startsWith('    ') ? line.slice(4) : line).join('\n');
}

// 上流の kernel が返す「標本の再生に足す確保量」の代わり。payload の頭から、上流の sfzSampleCacheFootprint と同じ式で
// キャッシュ分を数え、他の分（固定）を足す。呼び手の「最小の枚数でのキャッシュ分を引いた残り」が負にならないための写し。
export function emulatedEstimate(control, other = 256 * 1024) {
    const words = new Uint32Array(control.buffer.slice(control.byteOffset, control.byteOffset + control.byteLength), 32);
    // 常駐の payload（v6・v7）には標本の表もキャッシュも無い
    if (![8, 9, 10].includes(words[1])) return other;
    const table = words[12], count = words[13], slots = words[14], storage = words[15] === 2;
    const slots16 = storage ? words[16] : 0, rowWords = storage ? 16 : 12;
    let channels = 1;
    for (let sample = 0; sample < count; sample++) if (words[table + sample * rowWords + 2] === 2) channels = 2;
    let buckets = 1;
    while (buckets < slots * 4) buckets *= 2;
    return 4096 * channels * ((slots - slots16) * 4 + slots16 * 2) + slots * 32 + buckets * 4 +
        count * (2 * 16 + (storage ? 2 : 0)) + 4096 * 24 + slots * 16 + 64 * 4096 + other;
}

export function makeHost(root, context, { estimate = emulatedEstimate } = {}) {
    const U8 = vm.runInContext('Uint8Array', context), F32 = vm.runInContext('Float32Array', context);
    const handles = new Map();
    let next = 1;
    const register = file => { const handle = next++; handles.set(handle, file); return handle; };
    const delivered = {};
    const estimates = [];
    const reads = [];
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
        readRange: (handle, offset, length) => { reads.push([handle, offset, length]); return readFrom(handle, offset, length); },
        isCurrent: () => true,
        log: () => {},
        deliver: (name, bytes) => { delivered[name] = Buffer.from(new Uint8Array(bytes.buffer ?? bytes, bytes.byteOffset ?? 0, bytes.byteLength)); },
        decode: bytes => decodeWav(new Uint8Array(bytes.buffer ?? bytes, bytes.byteOffset ?? 0, bytes.byteLength), F32),
        estimate: (control, payloadBytes, sampleRate, channels, maxFrames, bpm, kind, formatTag) => {
            const bytes = estimate(Buffer.from(new Uint8Array(control.buffer ?? control, control.byteOffset ?? 0, control.byteLength)));
            estimates.push({ controlBytes: control.byteLength, payloadBytes, sampleRate, channels, maxFrames, bpm, kind, formatTag, bytes });
            return bytes;
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
    return { host, register, delivered, estimates, reads };
}

export function realm(root, options = {}) {
    const context = vm.createContext({});
    const made = makeHost(root, context, options);
    context.__et = made.host;
    vm.runInContext('delete globalThis.console', context);
    vm.runInContext(read(path.join(resources, 'effetune-sfz-prelude.js')), context);
    vm.runInContext(read(path.join(resources, 'effetune-sfz.js')), context);
    vm.runInContext(glueSource(), context);
    const api = vm.runInContext('__etSfz', context);
    api.configure(options.maxBytes ?? 256 * 1024 * 1024, false);
    return { context, api, ...made };
}

// フォルダ（{ 名前: { text | b64 } }）をファイルにして、JS へ渡す一覧（hostFiles の入力）を作る
export function writeFolder(r, root, folder, decodeBase64) {
    const files = [];
    for (const [name, value] of Object.entries(folder)) {
        const file = path.join(root, '..', `${path.basename(root)}-${name.replace(/[\/]/g, '_')}`);
        fs.writeFileSync(file, value.text !== undefined ? Buffer.from(value.text, 'utf8') : Buffer.from(decodeBase64(value.b64)));
        files.push({ handle: r.register(file), size: fs.statSync(file).size, lastModified: 0, name: name.split('/').pop(), path: name });
    }
    return JSON.stringify(files);
}

export const geometryJSON = (extra = {}) => JSON.stringify({ sampleRate: 48000, processingChannels: 2, maxFrames: 4096,
    minimumPhysicalBpm: 0, playerKind: 0, ...extra });
