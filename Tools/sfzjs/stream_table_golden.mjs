// Tools/sfzjs/stream_table_golden.mjs
// 流し込みの SFZ（load_*・予算超え）を、置いてある束ねと glue で取り込み → prepare して、Swift の SFZStreamTable.swift が読むものを
// 見本にする。入れ物（.sfzbank）・payload（制御の部分 = 全体）・glue が返す streamSamples・入れ物の外の標本のバイト列。
// Swift の SFZStreamTableTests がこれを読み、payload の表・resident のページ・標本の読み口（WAV は入れ物の中のまま）を確かめる。
//
//   node Tools/sfzjs/stream_table_golden.mjs [出力先]
//
// 入力は Tests/Fixtures/SFZ/sfz-golden.json の streamedImports（フォルダの中身）。上流の pin は要らない（束ねだけで走る）。
// stream.test.mjs が、この出力が今の束ね・glue から作り直したものと同じであることを見る。
//
// 出力: Tests/Fixtures/SFZ/stream-table-golden.json

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { fromB64, b64 } from '../golden/sfz_runner.mjs';
import { geometryJSON, read, realm, repo, writeFolder } from './glue_host.mjs';

export const defaultOut = path.join(repo, 'Tests', 'Fixtures', 'SFZ', 'stream-table-golden.json');
export const caseNames = ['streamed-load-opcodes', 'streamed-effects', 'streamed-generators'];

export async function build() {
    const golden = JSON.parse(read(path.join(repo, 'Tests', 'Fixtures', 'SFZ', 'sfz-golden.json')));
    const cases = [];
    for (const name of caseNames) {
        const item = golden.streamedImports.find(candidate => candidate.name === name);
        const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sfzstream-'));
        try {
            const r = realm(root, { maxBytes: item.maxBytes });
            const list = writeFolder(r, root, item.folder, fromB64);
            const entry = JSON.parse(await r.api.importFolder(list, item.selected));
            const prepared = JSON.parse(await r.api.prepare(entry.id, geometryJSON()));
            const inline = {};
            for (const sample of prepared.streamSamples) if (sample.inline) inline[sample.index] = b64(r.delivered[`stream:${sample.index}`]);
            cases.push({ name, id: entry.id, tableVersion: prepared.tableVersion, payloadBytes: prepared.payloadBytes,
                bank: b64(fs.readFileSync(path.join(root, `${entry.id}.sfzbank`))), control: b64(r.delivered.control),
                streamSamples: prepared.streamSamples, inline });
        } finally { fs.rmSync(root, { recursive: true, force: true }); }
    }
    return { note: 'Tools/sfzjs/stream_table_golden.mjs が作る。手で直さない。', cases };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    const out = path.resolve(process.argv[2] ?? defaultOut);
    fs.writeFileSync(out, `${JSON.stringify(await build(), null, 2)}\n`);
    console.log(`${path.relative(repo, out)} written`);
}
