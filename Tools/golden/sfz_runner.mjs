// sfz_runner.mjs
// SFZ の見本（Tests/Fixtures/SFZ/sfz-golden.json）の「走らせ方」。**他のファイルを import せず（b64 は自前）、Node にも Buffer にも頼らない**
// （JavaScriptCore の素のコンテキストでも、export を外せばそのまま動く）。
//
// 上流の js/sfz/*.js（Tools/golden/sfz_golden.mjs）と、置いてある束ね（Tools/sfzjs/bundle.test.mjs）の両方を、
// この同じ関数が走らせる。2 つの答えの差はそのまま、束ねが上流とずれた印になる。
// 入力の作り方は Tools/golden/sfz_cases.mjs。
//
// api = 上流のモジュールを集めたもの（束ねなら ETSFZ）。ctx = その realm の部品（U8 = Uint8Array、F32 = Float32Array、
// Blob、File）。ctx.onPayload(payload) は取り込み・資産を作った直後に呼ばれる（束ねの試験が、差し込んだ PCM の書き手の分を
// 埋めるのに使う）。ctx.skipReopen は取り込み後の開き直しを飛ばす。
// 乱数（取り込みの id）は呼ぶ側が fixedRandom で固定する（上流は crypto.getRandomValues、束ねは __et.random）。
//
// 音のファイルは 16 bit PCM の小さな WAV。上流の decode の代わりに、この WAV を読む小さな関数を渡す。
// Swift の試験も同じ読みをするので、読みの差は入らない。


export const encoder = new TextEncoder();

const tagOf = value => Object.prototype.toString.call(value);

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
export function b64(bytes) {
    let out = '';
    for (let i = 0; i < bytes.length; i += 3) {
        const a = bytes[i], b = bytes[i + 1] ?? 0, c = bytes[i + 2] ?? 0;
        out += B64[a >> 2] + B64[((a & 3) << 4) | (b >> 4)] +
            (i + 1 < bytes.length ? B64[((b & 15) << 2) | (c >> 6)] : '=') + (i + 2 < bytes.length ? B64[c & 63] : '=');
    }
    return out;
}
export function fromB64(text, U8 = Uint8Array) {
    const clean = text.replace(/=+$/, '');
    const out = new U8(Math.floor(clean.length * 3 / 4));
    let bits = 0, value = 0, at = 0;
    for (const char of clean) {
        value = (value << 6) | B64.indexOf(char);
        bits += 6;
        if (bits >= 8) { bits -= 8; out[at++] = (value >> bits) & 255; value &= (1 << bits) - 1; }
    }
    return out;
}

// 取り込みの id（12 バイトの乱数）を決まった値にする。a0a1a2…ab
export function fixedRandom(bytes) {
    for (let i = 0; i < bytes.length; i++) bytes[i] = (0xa0 + i) & 255;
    return bytes;
}

// 結果を JSON に落とす。Map・配列の面・Blob も、realm をまたいでも同じ形になる（instanceof を使わない）。
// 領域の欠けた鍵（undefined）は null に揃える。
export function encoded(value) {
    return JSON.parse(JSON.stringify(value, (key, v) => {
        if (v === undefined) return null;
        switch (tagOf(v)) {
            case '[object Map]': return Object.fromEntries([...v]);
            case '[object Set]': return [...v];
            case '[object Uint8Array]': return { b64: b64(v) };
            case '[object ArrayBuffer]': return { b64: b64(new Uint8Array(v)) };
            case '[object Float32Array]':
            case '[object Float64Array]':
            case '[object Uint32Array]': return Array.from(v);
            case '[object Blob]':
            case '[object File]': return { blob: v.size };
            default: return v;
        }
    }));
}


const failure = error => ({ error: error?.code ?? null, message: error?.message ?? String(error) });

// 試験用の decode。WAV の 16 bit PCM を float の面へ（/ 32768）。Swift の試験も同じ式。
export function decodeWav(input, F32 = Float32Array) {
    const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const channels = view.getUint16(22, true);
    const sampleRate = view.getUint32(24, true);
    const frames = (view.getUint32(40, true)) / (channels * 2);
    const planes = Array.from({ length: channels }, () => new F32(frames));
    for (let f = 0; f < frames; f++) {
        for (let c = 0; c < channels; c++) planes[c][f] = view.getInt16(44 + (f * channels + c) * 2, true) / 32768;
    }
    return { sampleRate, channels: planes };
}


async function runParser(api, ctx, testCase, audio) {
    const files = new Map(Object.entries(testCase.files));
    const sampleNames = Object.keys(audio);
    try {
        const result = await api.parseSfz({
            selectedPath: testCase.selected,
            readText: async file => files.get(file) ?? null,
            hasSample: file => sampleNames.includes(file),
            ...(testCase.resolve === 'identity' && { resolveSample: async sample => sample }),
            ...(testCase.defines && { defines: new Map(Object.entries(testCase.defines)) }),
            maxBytes: testCase.maxBytes ?? 256 * 1024 * 1024,
            onDiagnostic: () => {}
        });
        return encoded(result);
    } catch (error) {
        return failure(error);
    }
}


function bankFiles(ctx, folder) {
    return new Map(Object.entries(folder).map(([name, body]) =>
        [name, body.text !== undefined ? ctx.U8.from(encoder.encode(body.text)) : fromB64(body.b64, ctx.U8)]));
}


async function runBank(api, ctx, testCase) {
    const files = bankFiles(ctx, testCase.files);
    const bytes = api.encodeSfzBank(testCase.selectedPath, files, { warnings: testCase.warnings });
    const decoded = api.decodeSfzBank(bytes);
    return { container: b64(bytes), id: await api.identifySfzBank(bytes),
        decoded: { selectedPath: decoded.selectedPath, warnings: decoded.warnings, paths: [...decoded.files.keys()] } };
}


function runBadBank(api, ctx, item) {
    const files = bankFiles(ctx, item.files);
    let bytes;
    if (item.warnings) {
        // 上流の encode は警告の中身を調べない。decode が弾くことを見る
        bytes = api.encodeSfzBank(item.selectedPath, files, { warnings: item.warnings });
    } else {
        const good = api.encodeSfzBank(item.selectedPath, files);
        bytes = item.truncate ? good.slice(0, good.length - item.truncate) : good.slice();
        if (item.mutate) new DataView(bytes.buffer).setUint32(item.mutate.offset, item.mutate.value, true);
    }
    let error = null;
    try { api.decodeSfzBank(bytes); } catch (e) { error = e.code ?? 'other'; }
    return { bytes: b64(bytes), error };
}


async function runAsset(api, ctx, testCase, audio) {
    const samples = new Map(testCase.samples.map(name => [name, decodeWav(audio[name], ctx.F32)]));
    // 試験の入力は realm をまたぐので、領域の opcodes も素のまま渡る
    const regions = testCase.regions.map(item => ({ ...item }));
    const warnings = [];
    try {
        const result = api.packSfzAsset(regions, samples, {
            maxBytes: testCase.maxBytes ?? 256 * 1024 * 1024, onWarning: warning => warnings.push(warning), onDiagnostic: () => {}
        });
        ctx.onPayload?.(result.payload);
        return encoded({ payload: new Uint8Array(result.payload), samples: result.samples, channels: result.channels,
            sampleRate: result.sampleRate, layout: result.layout, formatTag: result.formatTag, rateDivider: result.rateDivider,
            headBlock: result.headBlock, processingChannels: result.processingChannels, warmupSamples: result.warmupSamples,
            tailSeconds: result.tailSeconds, unsupportedRuntime: result.unsupportedRuntime, footprintBytes: result.footprintBytes, warnings });
    } catch (error) {
        return failure(error);
    }
}


function runBudget(api, input, audio, { maxBytes }) {
    const frames = { 'a.wav': [600, 1], 'b one.wav': [500, 2], 'c.wav': [300, 1], 'x.wav': [100, 1] };
    const metadata = new Map(Object.entries(frames).map(([name, [n, channels]]) =>
        [name, { size: audio[name].length, frames: n, channels }]));
    try {
        const selection = api.selectSfzRegionsForBudget(input.regions, metadata, maxBytes, input.definitionBytes);
        return { reduced: selection.reduced, regionCount: selection.regions.length };
    } catch (error) {
        return failure(error);
    }
}


const fileClass = File => class RootFile extends File {
    constructor(parts, name, options, relative) { super(parts, name, options); this._relative = relative; }
    get webkitRelativePath() { return this._relative; }
};


// 固定の見積り（カーネルの値ではない）。足し算の式が正しく通ることだけを見る
const fixedEstimate = async (payload, context, formatTag) => 4096 + 64 * context.processingChannels + context.maxFrames + (formatTag === 1 ? 0 : 1);

const geometry = { sampleRate: 48000, processingChannels: 2, maxFrames: 512, minimumPhysicalBpm: 0, playerKind: 0 };


function resolveFolder(ctx, folder) {
    return Object.entries(folder).map(([file, body]) => ({ file, bytes: body.text !== undefined ? ctx.U8.from(encoder.encode(body.text)) : fromB64(body.b64, ctx.U8) }));
}


function memoryBackend(ctx, written, { streaming }) {
    const backend = {
        cleanupTemporary: async () => {},
        read: async key => written.get(key) ?? null,
        writeAtomic: async (key, bytes) => { written.set(key, bytes); },
        remove: async key => { written.delete(key); }
    };
    if (streaming) {
        backend.writeSfzBankFile = async (name, blob) => { written.set(name, new ctx.U8(await blob.arrayBuffer())); };
        backend.readSfzBankFile = async name => written.has(name) ? new ctx.File([written.get(name)], name, { lastModified: 0 }) : null;
    }
    return backend;
}


// 上流の prepareStreamedSfzBank の代わり。流し込みの読み手は使わず、v8 の入れ物だけを本物の packer で作る。
// 呼ばれ方（id・領域の数・標本の寸法・定義のバイト数）を記録に残す
function streamedStub(api, ctx, calls) {
    return async ({ id, parsed, metadata, maxBytes, definitionBytes, preparationContext, estimateEffectBytes }) => {
        const entries = [...metadata].sort(([a], [b]) => (a < b ? -1 : 1));
        calls.push({ id, regionCount: parsed.regions.length, definitionBytes, hasContext: Boolean(preparationContext),
            metadata: entries.map(([path, info]) => ({ path, size: info.size, frames: info.frames ?? null, channels: info.channels ?? null, sampleRate: info.sampleRate ?? null })) });
        const samples = new Map(entries.map(([path, info]) => [path,
            { frames: info.frames, channels: info.channels, sampleRate: info.sampleRate, revision: 'b'.repeat(64) }]));
        const descriptor = api.packStreamedSfzAsset(parsed.regions, samples, { cacheSlots: 8, maxBytes,
            modulation: parsed.modulation, effects: parsed.effects, onDiagnostic: () => {}, onWarning: () => {} });
        if (preparationContext) {
            const native = await estimateEffectBytes(descriptor.payload, preparationContext, descriptor.formatTag ?? 1);
            descriptor.preparationContext = preparationContext;
            descriptor.nativePreparationBytes = native;
            descriptor.processingChannels = preparationContext.processingChannels;
            descriptor.footprintBytes = descriptor.payload.byteLength + native;
        }
        descriptor.unsupportedOpcodes = [...(parsed.unsupportedOpcodes || [])];
        return { descriptor, sampleCount: samples.size, regionCount: new Uint32Array(descriptor.payload, 32)[2],
            ...(parsed.warnings?.length && { warnings: parsed.warnings }) };
    };
}


function summarize(prepared, reference = null) {
    if (!prepared) return null;
    const descriptor = prepared.descriptor;
    const words = new Uint32Array(descriptor.payload, 32, 2);
    const payload = b64(new Uint8Array(descriptor.payload));
    return { payload: payload === reference ? { same: true } : { b64: payload }, tableVersion: words[1], formatTag: descriptor.formatTag,
        warnings: prepared.warnings ?? [], regionCount: prepared.regionCount, sampleCount: prepared.sampleCount,
        unsupportedOpcodes: descriptor.unsupportedOpcodes ?? [], incomplete: descriptor.incomplete ?? false,
        tailSeconds: descriptor.tailSeconds ?? null, warmupSamples: descriptor.warmupSamples ?? null,
        unsupportedRuntime: descriptor.unsupportedRuntime ?? [],
        presentation: prepared.presentation ? { ...prepared.presentation, imageBlob: undefined, imageBytes: prepared.presentation.imageBlob?.size ?? null } : null,
        ...(descriptor.preparationContext && { preparationContext: descriptor.preparationContext,
            nativePreparationBytes: descriptor.nativePreparationBytes, processingChannels: descriptor.processingChannels,
            footprintBytes: descriptor.footprintBytes }) };
}


// 同じストアを開き直して prepare を呼ぶ（保存済みの入れ物を 0.17 の読みで読み直す道）。
// streamHost = 流し込みの道具を渡す host（0.17 の Electron/Android と同じ。非ストリームのバンクもこの道を通る）
async function reprepare(api, ctx, written, id, { streamHost, context, calls, reference = null }) {
    const backend = memoryBackend(ctx, written, { streaming: streamHost });
    const service = await new api.SfzLibraryService(backend, { getMaxBytes: () => 256 * 1024 * 1024, onDiagnostic: () => {} }).open();
    const options = { decode: async buffer => decodeWav(buffer, ctx.F32),
        ...(streamHost && { prepareStreamedBank: streamedStub(api, ctx, calls) }),
        ...(context && { preparationContext: api.sfzPreparationContext(geometry), estimateEffectBytes: fixedEstimate }) };
    try {
        return summarize(await service.prepare(id, options), reference);
    } catch (error) {
        return failure(error);
    }
}


async function runImport(api, ctx, testCase, audio) {
    const written = new Map();
    const calls = [];
    const File = fileClass(ctx.File);
    const streamHost = Boolean(testCase.streamHost);
    const backend = memoryBackend(ctx, written, { streaming: streamHost });
    const service = await new api.SfzLibraryService(backend, { getMaxBytes: () => testCase.maxBytes, onDiagnostic: () => {} }).open();
    const files = resolveFolder(ctx, testCase.folder).map(({ file, bytes }) =>
        new File([bytes], file.split('/').pop(), { lastModified: 0 }, `root/${file}`));
    const result = {};
    let entry, reference = null;
    try {
        const options = { decode: async buffer => decodeWav(buffer, ctx.F32),
            ...(streamHost && { prepareStreamedBank: streamedStub(api, ctx, calls) }) };
        entry = await service.importFolderFiles(files, testCase.selected, options);
        const prepared = service.prepared;
        // importedAt は取り込んだ時刻なので、作るたびに変わらないよう決まった値にする（CI の generated が比べる）。
        result.entry = { ...entry, importedAt: '2026-01-01T00:00:00.000Z' };
        result.bank = prepared.streamedSource ? { sourceBytes: prepared.bankBytes } : { b64: b64(written.get(`${entry.id}.sfzbank`)) };
        ctx.onPayload?.(prepared.value.descriptor.payload);
        result.prepared = summarize(prepared.value);
        reference = result.prepared.payload.b64 ?? null;
        if (calls.length) result.streamCalls = calls.splice(0);
    } catch (error) {
        Object.assign(result, failure(error));
    }
    if (entry && testCase.context && !ctx.skipReopen) {
        // 保存した入れ物を開き直して prepare（カーネルの見積りの代わりに固定の見積りを渡す）
        result.reopened = await reprepare(api, ctx, written, entry.id, { streamHost: false, context: true, calls, reference });
        result.reopenedOnStreamHost = await reprepare(api, ctx, written, entry.id, { streamHost: true, context: true, calls, reference });
        if (calls.length) result.reopenedStreamCalls = calls.splice(0);
    }
    return encoded(result);
}


async function runMigration(api, ctx, testCase) {
    const bytes = fromB64(testCase.container, ctx.U8);
    const id = await api.identifySfzBank(bytes);
    const written = new Map([[`${id}.sfzbank`, bytes]]);
    const entry = { id, name: testCase.entry.name, regionCount: testCase.entry.regionCount, size: bytes.byteLength,
        fileCount: testCase.entry.fileCount, importedAt: '2026-01-01T00:00:00.000Z' };
    written.set('index.json', ctx.U8.from(encoder.encode(JSON.stringify({ version: 1, entries: [entry] }))));
    const calls = [];
    const plain = await reprepare(api, ctx, written, id, { streamHost: false, context: true, calls });
    return encoded({ id, plain,
        streamHost: await reprepare(api, ctx, written, id, { streamHost: true, context: true, calls, reference: plain.payload?.b64 ?? null }) });
}

function runFolder(api, ctx, input) {
    const File = fileClass(ctx.File);
    return api.listSfzFolderFiles(input.paths.map(name => new File([ctx.U8.of(0)], name.split('/').pop(), { lastModified: 0 }, name)));
}

function runNormalize(api, item) {
    try { return { expected: api.normalizeSfzPath(item.input, item.directory) }; } catch (error) { return { error: error.code }; }
}


const merged = api => api.mergeSfzWarnings([{ code: 'invalid-regions', count: 2 }, { code: 'reduced-bank', count: 1 }],
    [{ code: 'invalid-regions', count: 5 }], undefined, [{ code: 'loop-points-ignored', count: 1 }]);

// 1 件ぶんの答え。節ごとの入力の形はこのファイルの *Inputs が決める
export async function expectedFor(section, api, ctx, item, audioBytes, extra) {
    // realm をまたいだ配列は deepStrictEqual で別物になる。素の JSON に揃えて返す
    return encoded(await dispatch(section, api, ctx, item, audioBytes, extra));
}

async function dispatch(section, api, ctx, item, audioBytes, extra) {
    switch (section) {
        case 'parser': return runParser(api, ctx, item, audioBytes);
        case 'bank': return runBank(api, ctx, item);
        case 'badBanks': return runBadBank(api, ctx, item);
        case 'asset': return runAsset(api, ctx, item, audioBytes);
        case 'budget': return runBudget(api, extra.budget, audioBytes, item);
        case 'imports':
        case 'streamedImports': return runImport(api, ctx, item, audioBytes);
        case 'migration': return runMigration(api, ctx, item);
        case 'folder': return encoded(runFolder(api, ctx, item));
        case 'normalize': return runNormalize(api, item);
        default: throw new Error(`unknown section ${section}`);
    }
}

export const mergedWarnings = merged;

