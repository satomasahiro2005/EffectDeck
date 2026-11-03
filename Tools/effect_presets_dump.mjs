// effect_presets_dump.mjs
// 上流のプラグインが持つ出荷時プリセット（System Presets）を JSON で吐く。
//
// 上流は各プラグイン .js の先頭に定数表を置き、クラスに
// `static getSystemPresetGroups()` を生やしている
// （plugins/dynamics/power_amp_sag.js:8-20、plugins/saturation/tube_simulator.js:6094-6103）。
// Tube Simulator のグループだけは静的な表ではなく spread と filter で組み立てる
// （tube_simulator.js:483-503）ので、正規表現では取れない。**評価するしかない。**
//
// 評価のやり方は上流のテスト道具をそのまま真似ている
// （tests/tools/tube-simulator-lineamp/calibrate-listening-presets.mjs:277-310）。
// PluginBase は registerProcessor() だけ持つ空のクラスで足りる。
// クラス本体の評価に DOM は要らない（createUI は呼ばない）。
//
//   node Tools/effect_presets_dump.mjs [plugins ディレクトリ]
//
// 出す形（Tools/gen_effect_presets.py が食う）:
//   [ { "name": "Tube Simulator",
//       "groups": [ { "label": "Pre", "presets": [ { "id":…, "label":…, "params": {…} } ] } ] } ]

// 評価できなかったプラグイン（getSystemPresetGroups() が配列を返さないものも）は stderr に
// `!! <rel> を評価できない: …`、plugins.txt に在るのに .js が無いものは `!! <rel>.js が無い` と出して
// 飛ばす。gen_effect_presets.py は ET_STRICT=1 のとき、その行を見て止める。
//
// 試験（node --test Tools/effect_presets_dump.test.mjs）から読めるよう、関数を export し、
// 直接起動されたときだけ main を走らせる。

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

// plugins.txt の [plugins] 節。1 行が
//   analyzer/level_meter: Level Meter | Analyzer | LevelMeterPlugin | css
export function readPluginList(file) {
    const out = [];
    let inPlugins = false;
    for (const raw of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
        const line = raw.trim();
        if (line.startsWith('[')) { inPlugins = line === '[plugins]'; continue; }
        if (!inPlugins || !line || line.startsWith('#')) continue;
        const colon = line.indexOf(':');
        if (colon < 0) continue;
        const rel = line.slice(0, colon).trim();
        const fields = line.slice(colon + 1).split('|').map(s => s.trim());
        if (fields.length < 3) continue;
        out.push({ rel, name: fields[0], className: fields[2] });
    }
    return out;
}

// vm の realm から出た配列・オブジェクトはこちらの prototype を持たないので、
// JSON を通して持ち帰る（上流の道具は Array.from で同じことをしている）。
function rehome(value) {
    return JSON.parse(JSON.stringify(value));
}

export function groupsOf(source, className, filename) {
    const context = vm.createContext({
        PluginBase: class { registerProcessor() {} },
        console,
        performance: { now: () => 0 },
        window: {},
    });
    vm.runInContext(
        `${source}\n;window.__groups = ${className}.getSystemPresetGroups();`,
        context, { filename });
    const groups = context.window.__groups;
    // 黙って [] にすると、そのプラグインのプリセットが !! 無しで消える。投げて dumpPlugins に報せさせる。
    if (!Array.isArray(groups)) {
        throw new TypeError(`${className}.getSystemPresetGroups() が配列でない（${groups === null ? 'null' : typeof groups}）`);
    }
    return rehome(groups).map(group => ({
        label: typeof group.label === 'string' ? group.label : '',
        presets: (group.presets || []).map(p => ({
            id: String(p.id), label: String(p.label), params: p.params || {},
        })),
    }));
}

// plugins.txt に載っているプラグインのうち、出荷時プリセットを持つものを並びのまま返す。
// 評価できなかったもの・.js が無いものは report に `!! …` を渡して飛ばす。
export function dumpPlugins(pluginsDir, report) {
    const out = [];
    for (const { rel, name, className } of readPluginList(path.join(pluginsDir, 'plugins.txt'))) {
        const file = path.join(pluginsDir, `${rel}.js`);
        // 固定した版では 108 本とも在る。無ければ上流が動かした（そのプリセットが黙って消える）。
        if (!fs.existsSync(file)) {
            report(`!! ${rel}.js が無い（plugins.txt には在る）`);
            continue;
        }
        const source = fs.readFileSync(file, 'utf8');
        // 持っていないものは評価もしない。読むだけで済む篩い。
        if (!source.includes('getSystemPresetGroups')) continue;
        let groups;
        try {
            groups = groupsOf(source, className, `${rel}.js`);
        } catch (e) {
            report(`!! ${rel} を評価できない: ${e.message}`);
            continue;
        }
        if (groups.some(g => g.presets.length > 0)) out.push({ name, groups });
    }
    return out;
}

function main(argv) {
    const pluginsDir = argv[0]
        ? path.resolve(argv[0])
        : path.join(here, '..', 'Vendor', 'effetune', 'plugins');
    const listFile = path.join(pluginsDir, 'plugins.txt');
    if (!fs.existsSync(listFile)) {
        process.stderr.write(`!! plugins.txt が無い ${listFile}\n`);
        return 1;
    }
    const out = dumpPlugins(pluginsDir, message => process.stderr.write(`${message}\n`));
    process.stdout.write(JSON.stringify(out, null, 1));
    return 0;
}

// process.exit() は使わない。Mac のパイプは stdout が非同期なので、
// 書き切る前に終わり 65536 バイトで切れる。exitCode なら出し切ってから終わる。
function isEntry() {
    if (!process.argv[1]) return false;
    try {
        const self = fs.realpathSync(fileURLToPath(import.meta.url));
        return pathToFileURL(fs.realpathSync(process.argv[1])).href === pathToFileURL(self).href;
    } catch {
        return false;
    }
}

if (isEntry()) {
    process.exitCode = main(process.argv.slice(2));
}
