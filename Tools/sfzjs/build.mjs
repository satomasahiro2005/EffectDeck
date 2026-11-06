// Tools/sfzjs/build.mjs
// 上流の js/sfz・js/sf2 を、JavaScriptCore で評価できる 1 本のクラシックスクリプトへ束ねる。
//
//   npm ci --prefix Tools/sfzjs
//   node Tools/sfzjs/build.mjs                 # 束ねて Resources/SFZ に書く
//   node Tools/sfzjs/build.mjs --update-modules # 束ねる木が変わったと承知の上で modules.txt を書き直す
//
// 1. 指している版の上流（HEADのgitlink）を Tools/golden/extract_pin.sh で展開する（作業ツリーの
//    Vendor/effetune は読まない）。EFFETUNE_ROOT があればそこを使う（Tools/golden/*.mjs と同じ約束）。
// 2. その js/ を作業用の場所へ写し、Patches の js-sfz パッチ（patchNames の順）を当てる。
// 3. entry.mjs を同じ場所へ写し、esbuild（IIFE・グローバル名 ETSFZ）で束ねる。
//    パスのコメントは absWorkingDir からの相対なので、手元でも CI でも同じバイトになる。
// 4. 束ねた木（metafile の inputs）を modules.txt と突き合わせる。上流が新しい import を足すと
//    ここで落ちる（足されたものを読んでから --update-modules で承知する）。
// 5. 出力は Sources/EffeTuneLive/Resources/SFZ/effetune-sfz.js（先頭に版の印）と、
//    prelude.js の写し effetune-sfz-prelude.js。どちらも手で直さない（CIの generated が作り直して差分を見る）。

import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const outDir = path.join(repo, 'Sources', 'EffeTuneLive', 'Resources', 'SFZ');
const bundleFile = path.join(outDir, 'effetune-sfz.js');
const preludeCopy = path.join(outDir, 'effetune-sfz-prelude.js');
// 上流の js/ へ当てるパッチ。別々のファイルに触れるので順は結果に効かないが、束ねの先頭の印にもこの順で書く。
const patchNames = ['effetune-js-sfz-pool-writer.diff', 'effetune-js-sfz-stream-table.diff'];
const modulesFile = path.join(here, 'modules.txt');
const updateModules = process.argv.includes('--update-modules');

const sha256 = data => crypto.createHash('sha256').update(data).digest('hex');
// 改行は LF に揃えて読む（Windows の autocrlf で版の印が変わらないように）
const readLf = file => fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
const fail = message => { console.error(`build.mjs: ${message}`); process.exit(1); };

// Windows で PATH の bash は WSL のことがある。Git for Windows のものを先に探す
function findBash() {
  if (process.platform !== 'win32') return 'bash';
  const candidates = [process.env.ET_BASH];
  for (const base of [process.env.ProgramFiles, process.env['ProgramFiles(x86)'], process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'Programs')]) {
    if (base) candidates.push(path.join(base, 'Git', 'bin', 'bash.exe'), path.join(base, 'Git', 'usr', 'bin', 'bash.exe'));
  }
  const exec = spawnSync('git', ['--exec-path'], { encoding: 'utf8' });
  if (exec.status === 0) candidates.push(path.resolve(exec.stdout.trim(), '..', '..', '..', 'bin', 'bash.exe'));
  return candidates.find(file => file && fs.existsSync(file)) ?? 'bash';
}

function pinRoot() {
  if (process.env.EFFETUNE_ROOT) return path.resolve(process.env.EFFETUNE_ROOT);
  const bash = findBash();
  const run = spawnSync(bash, [path.join(repo, 'Tools', 'golden', 'extract_pin.sh').replace(/\\/g, '/')], { encoding: 'utf8', cwd: repo });
  if (run.status !== 0) fail(`extract_pin.sh が失敗した（${run.status}）\n${run.stderr}`);
  let dir = run.stdout.trim().split('\n').pop();
  if (process.platform === 'win32' && dir.startsWith('/')) {
    // Git Bash の /tmp/... を Windows のパスへ
    const converted = spawnSync(bash, ['-c', 'cygpath -m "$1"', '_', dir], { encoding: 'utf8' });
    if (converted.status !== 0) fail(`cygpath が失敗した: ${dir}`);
    dir = converted.stdout.trim();
  }
  return path.resolve(dir);
}

const root = pinRoot();
const pinFile = path.join(root, '.pin');
if (!fs.existsSync(path.join(root, 'js', 'sfz', 'asset.js'))) fail(`上流の js/sfz が無い: ${root}`);
if (!fs.existsSync(pinFile)) fail(`${pinFile} が無い（extract_pin.sh が作る .pin に版が書いてある）`);
const pin = fs.readFileSync(pinFile, 'utf8').trim();

// 作業用の場所。名前は版ごとに決まっていて、毎回作り直す（前の残りが混ざらない）
const work = process.env.ET_SFZJS_WORK ? path.resolve(process.env.ET_SFZJS_WORK) : path.join(os.tmpdir(), `effectdeck-sfzjs-${pin.slice(0, 12)}`);
fs.rmSync(work, { recursive: true, force: true });
fs.mkdirSync(work, { recursive: true });
fs.cpSync(path.join(root, 'js'), path.join(work, 'js'), { recursive: true });
fs.writeFileSync(path.join(work, 'entry.mjs'), readLf(path.join(here, 'entry.mjs')));

const patchTexts = patchNames.map(name => readLf(path.join(repo, 'Patches', name)));
for (const [index, patchText] of patchTexts.entries()) {
  const patchPath = path.join(work, 'patch.diff');
  fs.writeFileSync(patchPath, patchText);
  const applied = spawnSync('git', ['apply', '-p1', '--whitespace=nowarn', patchPath], { cwd: work, encoding: 'utf8' });
  if (applied.status !== 0) fail(`パッチが当たらない: ${patchNames[index]}（上流が動いたらパッチを作り直す）\n${applied.stderr}`);
  fs.rmSync(patchPath);
}

const result = await esbuild.build({
  absWorkingDir: work,
  entryPoints: ['entry.mjs'],
  outfile: 'effetune-sfz.js',
  bundle: true,
  format: 'iife',
  globalName: 'ETSFZ',
  platform: 'neutral',
  target: 'es2022',
  write: false,
  metafile: true,
  logLevel: 'silent',
});
// 出る警告は Worker の import.meta.url（EffectDeck は通らない道）だけのはず。増えたら見えるように出す
for (const warning of result.warnings) {
  const where = warning.location ? ` (${warning.location.file}:${warning.location.line})` : '';
  console.error(`esbuild warning: ${warning.text}${where}`);
}
if (result.outputFiles.length !== 1) fail(`出力が 1 本でない: ${result.outputFiles.length}`);
const body = result.outputFiles[0].text;

// 束ねた木の照合
const modules = Object.keys(result.metafile.inputs).sort();
const recorded = fs.existsSync(modulesFile) ? readLf(modulesFile).split('\n').filter(Boolean) : [];
const added = modules.filter(name => !recorded.includes(name));
const removed = recorded.filter(name => !modules.includes(name));
if (added.length || removed.length) {
  if (!updateModules) {
    console.error('build.mjs: 束ねたモジュールが modules.txt と違う。');
    for (const name of added) console.error(`  + ${name}`);
    for (const name of removed) console.error(`  - ${name}`);
    fail('上流が import を足した（または消した）。中身を読み、プレリュードで足りるか確かめてから --update-modules で承知する。');
  }
  fs.writeFileSync(modulesFile, `${modules.join('\n')}\n`);
  console.log(`modules.txt を書き直した（+${added.length} -${removed.length}）`);
}

const header = [
  '// effetune-sfz.js: 生成物。Tools/sfzjs/build.mjs が作る。手で直さない。',
  `// pin: ${pin}`,
  `// esbuild: ${esbuild.version}`,
  ...patchNames.map((name, index) => `// patch: ${name} sha256=${sha256(patchTexts[index])}`),
  `// sha256: ${sha256(body)}`,
  '',
].join('\n');

const write = (file, text) => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (fs.existsSync(file) && fs.readFileSync(file, 'utf8') === text) return;
  fs.writeFileSync(file, text);
};
write(bundleFile, header + body);
write(preludeCopy, readLf(path.join(here, 'prelude.js')));
console.log(`${path.relative(repo, bundleFile)} ${Buffer.byteLength(header + body)} bytes (${modules.length} modules, pin ${pin.slice(0, 8)})`);
