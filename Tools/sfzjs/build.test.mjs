// Tools/sfzjs/build.test.mjs
// 束ねを作り直して、置いてあるものと 1 バイトも違わないこと（作業場所が違っても同じ）を見る。
//
//   npm ci --prefix Tools/sfzjs
//   node --test Tools/sfzjs/build.test.mjs
//
// esbuild（npm ci）と、指している版の上流（Vendor/effetune の submodule か EFFETUNE_ROOT）が要る。
// 無い環境（checks ジョブなど）では飛ばす。CI の generated ジョブは build.mjs を直に回して git diff で見る。

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const resources = path.join(repo, 'Sources', 'EffeTuneLive', 'Resources', 'SFZ');
const outputs = ['effetune-sfz.js', 'effetune-sfz-prelude.js'].map(name => path.join(resources, name));
const hasEsbuild = fs.existsSync(path.join(here, 'node_modules', 'esbuild', 'package.json'));
const build = env => spawnSync(process.execPath, [path.join(here, 'build.mjs')], { encoding: 'utf8', env: { ...process.env, ...env } });

test('束ねを作り直すと、置いてあるものと同じバイトで、作業場所に依らない', { skip: !hasEsbuild && 'esbuild が無い（npm ci --prefix Tools/sfzjs）' }, t => {
  const committed = outputs.map(file => fs.readFileSync(file));
  const first = build({});
  if (first.status !== 0 && /extract_pin|上流の js\/sfz が無い|\.pin/.test(first.stderr)) { t.skip('指している版の上流が無い'); return; }
  assert.equal(first.status, 0, first.stderr);
  outputs.forEach((file, i) => assert.ok(fs.readFileSync(file).equals(committed[i]), `${path.basename(file)} が置いてあるものと違う（build.mjs を回してコミットする）`));
  const elsewhere = fs.mkdtempSync(path.join(os.tmpdir(), 'sfzjs-work-'));
  try {
    const second = build({ ET_SFZJS_WORK: path.join(elsewhere, 'a-different-directory-name') });
    assert.equal(second.status, 0, second.stderr);
    outputs.forEach((file, i) => assert.ok(fs.readFileSync(file).equals(committed[i]), `${path.basename(file)} が作業場所で変わった`));
  } finally { fs.rmSync(elsewhere, { recursive: true, force: true }); }
});

test('modules.txt に無いモジュールが増えたら、束ねは失敗する', { skip: !hasEsbuild && 'esbuild が無い（npm ci --prefix Tools/sfzjs）' }, t => {
  const modules = path.join(here, 'modules.txt');
  const original = fs.readFileSync(modules);
  const committed = outputs.map(file => fs.readFileSync(file));
  try {
    // 1 行消す = 束ねた木に「増えたもの」が出る
    const lines = original.toString('utf8').split('\n').filter(Boolean);
    fs.writeFileSync(modules, `${lines.filter(line => line !== 'js/sfz/md5.js').join('\n')}\n`);
    const run = build({});
    if (run.status !== 0 && /extract_pin|上流の js\/sfz が無い|\.pin/.test(run.stderr)) { t.skip('指している版の上流が無い'); return; }
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /\+ js\/sfz\/md5\.js/);
    outputs.forEach((file, i) => assert.ok(fs.readFileSync(file).equals(committed[i]), '失敗した束ねは出力を書き換えない'));
  } finally { fs.writeFileSync(modules, original); }
});
