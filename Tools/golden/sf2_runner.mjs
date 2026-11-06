// sf2_runner.mjs
// SoundFont（0.17 の js/sf2）の見本（Tests/Fixtures/SFZ/sf2-golden.json）の「走らせ方」。**import が無く、Node にも Buffer にも頼らない**。
// 上流の js/sf2（Tools/golden/sf2_golden.mjs）と、置いてある束ね（Tools/sfzjs/bundle.test.mjs）の両方を、この同じ関数が走らせる。
// 入力（SF2 のバイト列）は Tools/golden/sf2_golden.mjs が、上流の tests/helpers/sf2-fixture.mjs で作る。
//
// 各件は上流の tests/esm/sf2-parser.test.mjs の 11 の試験と同じ操作をして、試験が確かめている値を（それ以外も含めて）残す。
// api = { parseSf2, compileSf2, openSf2Source, sf2SamplerRegions, packSf2Modulation, packStreamedSfzAsset }
// ctx = { U8, F64 }（その realm の Uint8Array・Float64Array）

import { fromB64, encoded } from './sfz_runner.mjs';

const readerOf = bytes => ({ size: bytes.length, async readRange(offset, length) { return bytes.subarray(offset, offset + length); } });
const failure = error => ({ error: error?.code ?? null, message: error?.message ?? String(error) });
const generator = (operator, amount) => ({ operator, amount, unsignedAmount: amount });

const dumpParsed = parsed => ({ format: parsed.format, version: parsed.version, info: parsed.info, smplOffset: parsed.smplOffset,
    smplBytes: parsed.smplBytes, sm24Bytes: parsed.sm24Bytes, sm24Offset: parsed.sm24Offset, sampleFrames: parsed.sampleFrames,
    metadataBytes: parsed.metadataBytes, presets: parsed.presets,
    tables: Object.fromEntries(Object.entries(parsed.tables).map(([name, rows]) => [name, rows.length])) });
const dumpCompiled = compiled => ({ format: compiled.format, sourceProfile: compiled.sourceProfile, presets: compiled.presets,
    diagnostics: compiled.diagnostics,
    regions: compiled.regions.map(region => ({ presetIndex: region.presetIndex, bank: region.bank, program: region.program,
        sampleId: region.sampleId, keyRange: region.keyRange, velocityRange: region.velocityRange,
        generators: Array.from(region.generators), modulators: region.modulators, sample: region.sample })) });

// 試験 4 の、符号付き 32 bit を超える標本の置き場。標本のバイトは 1 つも読まれてはいけない
function hugePool(bytes, original) {
    const poolOffset = original.smplOffset, oldLength = original.sampleFrames * 2, extra = 0x80000000;
    const prefix = bytes.slice(0, poolOffset), suffix = bytes.subarray(poolOffset + oldLength);
    const view = new DataView(prefix.buffer, prefix.byteOffset, prefix.byteLength);
    view.setUint32(4, bytes.length + extra - 8, true);
    view.setUint32(poolOffset - 4, oldLength + extra, true);
    view.setUint32(poolOffset - 16, view.getUint32(poolOffset - 16, true) + extra, true);
    const reads = [];
    return { reads, reader: { size: bytes.length + extra, async readRange(offset, length) {
        reads.push([offset, length]);
        if (offset < poolOffset) return prefix.subarray(offset, offset + length);
        if (offset < poolOffset + oldLength + extra) throw new Error('sample data must not be read');
        const at = offset - poolOffset - oldLength - extra;
        return suffix.subarray(at, at + length);
    } } };
}

export async function runSf2Case(api, ctx, item) {
    const bytes = item.fixture ? fromB64(item.fixture, ctx.U8) : null;
    const open = () => api.parseSf2(readerOf(bytes));
    try {
        switch (item.kind) {
            case 'basic': {
                const source = await api.openSf2Source(readerOf(bytes));
                return encoded({ parsed: dumpParsed(source.parsed), compiled: dumpCompiled(source.compiled),
                    samples: source.samples, sourceBytes: source.sourceBytes, sampler: api.sf2SamplerRegions(source) });
            }
            case 'parse-only': return encoded(dumpParsed(await open()));
            case 'riff-length': {
                // RIFF の長さをファイル全体にする（本来は 8 バイト引く）
                const broken = bytes.slice();
                new DataView(broken.buffer).setUint32(4, broken.length, true);
                await api.parseSf2(readerOf(broken));
                return { error: null, message: 'parsed' };
            }
            case 'huge-pool': {
                const { reads, reader } = hugePool(bytes, await open());
                const parsed = await api.parseSf2(reader);
                return encoded({ presets: parsed.presets.length, sm24Offset: parsed.sm24Offset,
                    readsAbove2GiB: reads.some(([offset]) => offset > 0x80000000), readCount: reads.length });
            }
            case 'loop-defaults': {
                const parsed = await open();
                parsed.tables.igen[0] = generator(54, item.globalMode);
                if (item.localMode === null) parsed.tables.igen.splice(3, 1);
                else parsed.tables.igen[3] = generator(54, item.localMode);
                if (item.localMode === null) parsed.tables.ibag[2].generator--;
                // 同じインストゥルメント専用の generator は、プリセットでは無効のまま
                parsed.tables.pgen[0] = generator(54, 1);
                const compiled = api.compileSf2(parsed), region = compiled.regions[0];
                const source = { compiled, samples: [{ sampleId: 0, start: 0, frames: 64, path: 'sample:00000' }] };
                return encoded({ mode: region.generators[54], loopStart: region.sample.loopStart, loopEnd: region.sample.loopEnd,
                    sampler: api.sf2SamplerRegions(source)[0] });
            }
            case 'stereo-link': {
                const parsed = await open();
                parsed.tables.shdr[0].sampleType = 4;
                parsed.tables.shdr[0].sampleLink = 1;
                parsed.tables.shdr.splice(1, 0, { ...parsed.tables.shdr[0], sampleType: 2, sampleLink: 0 });
                return encoded(dumpCompiled(api.compileSf2(parsed)));
            }
            case 'chained-mod': {
                const parsed = await open();
                const values = [
                    { source: 0x81, destination: 0x8001, amount: 100, amountSource: 0, transform: 0 },
                    { source: 127, destination: 48, amount: 2, amountSource: 0, transform: 2 }
                ];
                parsed.tables.imod = [...values, {}];
                parsed.tables.ibag[1].modulator = 0;
                parsed.tables.ibag[2].modulator = 2;
                const chained = dumpCompiled(api.compileSf2(parsed));
                // 輪になったつながりは除かれる
                values[0].source = 127;
                values[1].destination = 0x8000;
                return encoded({ chained, circular: dumpCompiled(api.compileSf2(parsed)) });
            }
            case 'preset-index': {
                const parsed = await open();
                const result = { zero: api.compileSf2(parsed, { presetIndex: 0 }).presets };
                try { api.compileSf2(parsed, { presetIndex: 1 }); result.one = 'compiled'; } catch (error) { result.one = failure(error); }
                return encoded(result);
            }
            case 'unpitched': {
                const parsed = await open();
                parsed.tables.shdr[0].originalPitch = 255;
                const first = dumpCompiled(api.compileSf2(parsed));
                parsed.tables.igen.splice(4, 0, { operator: 58, amount: 72, unsignedAmount: 72 });
                parsed.tables.ibag[2].generator++;
                return encoded({ headerPitch: parsed.tables.shdr[0].originalPitch, first, rootKeyOverride: dumpCompiled(api.compileSf2(parsed)) });
            }
            case 'v9': case 'native': {
                const source = await api.openSf2Source(readerOf(bytes));
                const samples = new Map(source.samples.map(sample => [sample.path,
                    { frames: sample.frames, channels: 1, sampleRate: sample.sampleRate, revision: 'a'.repeat(64) }]));
                const descriptor = api.packStreamedSfzAsset(api.sf2SamplerRegions(source), samples, { cacheSlots: 8,
                    sourceProfile: source.compiled.sourceProfile, presets: source.compiled.presets, modulation: source.compiled });
                return encoded({ payload: new Uint8Array(descriptor.payload), footprintBytes: descriptor.footprintBytes,
                    sampleCacheBytes: descriptor.sampleCacheBytes, samples: descriptor.samples, formatTag: descriptor.formatTag,
                    processingChannels: descriptor.processingChannels, tailSeconds: descriptor.tailSeconds,
                    warmupSamples: descriptor.warmupSamples });
            }
            case 'linked-route': {
                const region = { generators: new ctx.F64(61), modulators: item.modulators };
                const packed = api.packSf2Modulation({ regions: [region, region] });
                return encoded({ section: packed });
            }
            default: throw new Error(`unknown SF2 case kind ${item.kind}`);
        }
    } catch (error) {
        return failure(error);
    }
}
