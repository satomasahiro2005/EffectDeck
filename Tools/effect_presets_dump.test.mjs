// effect_presets_dump.test.mjs
// effect_presets_dump.mjs の読み取りを確かめる。
//
//   node --test Tools/effect_presets_dump.test.mjs
//
// Tube Simulator のグループは静的な表ではなく spread と filter で組み立てる
// （plugins/saturation/tube_simulator.js:483-503）。評価して取れることをここで押さえる。

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { after } from 'node:test';

import { dumpPlugins, groupsOf, readPluginList } from './effect_presets_dump.mjs';

const made = [];
function tempDir() {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ettools-node-'));
    made.push(dir);
    return dir;
}
after(() => {
    for (const dir of made) fs.rmSync(dir, { recursive: true, force: true });
});

test('readPluginList reads only the [plugins] section', () => {
    const dir = tempDir();
    const file = path.join(dir, 'plugins.txt');
    fs.writeFileSync(file, [
        '[core]',
        'core/thing: Not A Plugin | Core | CorePlugin',
        '[plugins]',
        '# a comment',
        '',
        'analyzer/level_meter: Level Meter | Analyzer | LevelMeterPlugin | css',
        'saturation/tube_simulator: Tube Simulator | Saturation | TubeSimulatorPlugin\r',
        'broken line without colon',
        'eq/short: Too Short | Eq',
        '[styles]',
        'x/y: Style | S | StylePlugin',
    ].join('\n'));
    assert.deepEqual(readPluginList(file), [
        { rel: 'analyzer/level_meter', name: 'Level Meter', className: 'LevelMeterPlugin' },
        { rel: 'saturation/tube_simulator', name: 'Tube Simulator', className: 'TubeSimulatorPlugin' },
    ]);
});

test('groupsOf evaluates spread and filter groups (Tube Simulator shape)', () => {
    const source = `
const TUBE_PRESETS = Object.freeze([
    { id: 'pre-warm', label: 'Warm', stage: 'pre', params: { dr: -12, bs: [{ f: 100 }] } },
    { id: 'pow-push', label: 'Push', stage: 'power', params: { dr: -6 } },
    { id: 'both', label: 'Both', stage: 'both', params: { dr: -3 } },
]);
class TubeSimulatorPlugin extends PluginBase {
    static getSystemPresetGroups() {
        const pick = stage => TUBE_PRESETS.filter(p => p.stage === stage).map(({ stage: _, ...rest }) => ({ ...rest }));
        return [
            { label: 'Pre', presets: pick('pre') },
            { label: 'Power', presets: [...pick('power')] },
            { label: 'Pre+Power', presets: pick('both') },
            { presets: [] },
        ];
    }
}`;
    const groups = groupsOf(source, 'TubeSimulatorPlugin', 'tube.js');
    assert.deepEqual(groups.map(g => g.label), ['Pre', 'Power', 'Pre+Power', '']);
    assert.deepEqual(groups[0].presets, [{ id: 'pre-warm', label: 'Warm', params: { dr: -12, bs: [{ f: 100 }] } }]);
    assert.deepEqual(groups[1].presets.map(p => p.id), ['pow-push']);
    assert.equal(Object.getPrototypeOf(groups[0].presets[0].params), Object.prototype);
});

test('groupsOf throws when the class does not return an array', () => {
    // 黙って [] にすると、そのプラグインのプリセットが !! 無しで消える。
    const source = 'class P extends PluginBase { static getSystemPresetGroups() { return null; } }';
    assert.throws(() => groupsOf(source, 'P', 'p.js'), /配列でない/);
});

test('dumpPlugins reports a plugin that throws or is missing and keeps the others', () => {
    const dir = tempDir();
    fs.mkdirSync(path.join(dir, 'dynamics'));
    fs.writeFileSync(path.join(dir, 'plugins.txt'),
        '[plugins]\ndynamics/sag: Power Amp Sag | Dynamics | SagPlugin\n'
        + 'dynamics/bad: Bad | Dynamics | BadPlugin\ndynamics/plain: Plain | Dynamics | PlainPlugin\n'
        + 'dynamics/missing: Missing | Dynamics | MissingPlugin\n');
    fs.writeFileSync(path.join(dir, 'dynamics', 'sag.js'),
        "class SagPlugin extends PluginBase { static getSystemPresetGroups() {"
        + " return [{ label: '', presets: [{ id: 'soft', label: 'Soft', params: { sg: 1 } }] }]; } }");
    fs.writeFileSync(path.join(dir, 'dynamics', 'bad.js'),
        "class BadPlugin extends PluginBase { static getSystemPresetGroups() { throw new Error('boom'); } }");
    fs.writeFileSync(path.join(dir, 'dynamics', 'plain.js'), 'class PlainPlugin extends PluginBase {}');
    const errors = [];
    const out = dumpPlugins(dir, message => errors.push(message));
    assert.deepEqual(out, [{
        name: 'Power Amp Sag',
        groups: [{ label: '', presets: [{ id: 'soft', label: 'Soft', params: { sg: 1 } }] }],
    }]);
    assert.equal(errors.length, 2, errors.join('\n'));
    assert.match(errors[0], /^!! dynamics\/bad .*boom/);
    assert.match(errors[1], /^!! dynamics\/missing\.js が無い/);
});

test('dumpPlugins reports a method that returns something other than an array', () => {
    const dir = tempDir();
    fs.writeFileSync(path.join(dir, 'plugins.txt'), '[plugins]\nnull: Null | X | NullPlugin\n');
    fs.writeFileSync(path.join(dir, 'null.js'),
        'class NullPlugin extends PluginBase { static getSystemPresetGroups() { return undefined; } }');
    const errors = [];
    assert.deepEqual(dumpPlugins(dir, message => errors.push(message)), []);
    assert.equal(errors.length, 1);
    assert.match(errors[0], /^!! null .*配列でない/);
});
