// ir_library_id_golden.mjs
// IRの置き場の鍵（IRLibraryFiles.key）の見本を、上流のir-library-id.jsそのものに作らせる。
//
// プリセットはIRの中身を持たず鍵だけを書くので、鍵の作り方が上流とずれると、web版で作った
// プリセットをこちらで開いたときにIRが「Missing from the library」になる。
// 上流のjs/ir-library/ir-library-id.jsはWebCrypto（globalThis.crypto.subtle）だけを使うので、
// node 22でそのまま読める。入力は決まった乱数で作り、入力（base64）と上流の答えの両方を
// Tests/Fixtures/IR/ir-library-id-golden.jsonへ書く。Swift側は入力を読んで鍵を作り、答えと照合する
// （Tests/Unit/IRLibraryKeyTests.swift）。
//
//   root=$(bash Tools/golden/extract_pin.sh)
//   EFFETUNE_ROOT="$root" node Tools/golden/ir_library_id_golden.mjs [出力先]
//
// 長さはSHA-256の詰め物の境目（55/56/63/64/65バイトと、2ブロック目の119/120/128）を含めてある。Linuxの単体テストは
// CryptoKitの代わりにTests/Linux/Shims/CryptoKitの実装で鍵を作るので、その境目もここで見る。
// 出力は鍵の順に並べた決まった形（同じ上流からは同じバイト列）。

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.join(here, '..', '..');

const upstream = process.env.EFFETUNE_ROOT;
if (!upstream) {
    console.error('ir_library_id_golden.mjs: EFFETUNE_ROOT が無い（bash Tools/golden/extract_pin.sh の出力を渡す）');
    process.exit(2);
}
const idFile = path.resolve(upstream, 'js', 'ir-library', 'ir-library-id.js');
const outFile = path.resolve(process.argv[2] ?? path.join(repo, 'Tests', 'Fixtures', 'IR', 'ir-library-id-golden.json'));

const { identifySingleIr, identifyPairedIr } = await import(pathToFileURL(idFile).href);

// ---- 入力 ----

function lcgBytes(count, seed) {
    let state = seed >>> 0;
    const out = new Uint8Array(count);
    for (let i = 0; i < count; i += 1) {
        state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
        out[i] = state >>> 24;
    }
    return out;
}

const inputs = {
    empty: new Uint8Array(0),
    abc: new TextEncoder().encode('abc'),
    lcg55: lcgBytes(55, 55),
    lcg56: lcgBytes(56, 56),
    lcg63: lcgBytes(63, 63),
    lcg64: lcgBytes(64, 64),
    lcg65: lcgBytes(65, 65),
    lcg119: lcgBytes(119, 119),
    lcg120: lcgBytes(120, 120),
    lcg128: lcgBytes(128, 128),
    lcg1000: lcgBytes(1000, 1000)
};

// 左右の組。並びを入れ替えると別の鍵になることも見る。
const pairs = [
    ['empty', 'empty'],
    ['abc', 'abc'],
    ['lcg1000', 'lcg128'],
    ['lcg128', 'lcg1000'],
    ['lcg55', 'lcg64']
];

// ---- 上流の答え ----

const single = [];
for (const name of Object.keys(inputs).sort()) {
    const { irId, sha256 } = await identifySingleIr(inputs[name]);
    single.push({ input: name, irId, sha256 });
}

const paired = [];
for (const [left, right] of pairs) {
    const { irId, leftSha256, rightSha256 } = await identifyPairedIr(inputs[left], inputs[right]);
    paired.push({ left, right, irId, leftSha256, rightSha256 });
}

function sortKeys(value) {
    if (Array.isArray(value)) return value.map(sortKeys);
    if (value && typeof value === 'object') {
        return Object.fromEntries(Object.keys(value).sort().map((k) => [k, sortKeys(value[k])]));
    }
    return value;
}

const golden = sortKeys({
    generator: 'Tools/golden/ir_library_id_golden.mjs',
    source: 'js/ir-library/ir-library-id.js',
    inputs: Object.fromEntries(Object.keys(inputs).sort()
        .map((name) => [name, Buffer.from(inputs[name]).toString('base64')])),
    single,
    paired
});

fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, JSON.stringify(golden, null, 2) + '\n');
console.log(`ir_library_id_golden.mjs: single ${single.length}, paired ${paired.length} -> ${path.relative(repo, outFile)}`);
