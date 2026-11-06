// sfz_cases.mjs
// SFZ の見本（Tests/Fixtures/SFZ/sfz-golden.json）の「入力」を作る（Node 専用: WAV・md5・埋め込み <sample> の符号化）。
//
// 入力を上流に流して答えを書くのが Tools/golden/sfz_golden.mjs、見本の入力を置いてある束ねへ流して答えと照らすのが
// Tools/sfzjs/bundle.test.mjs。どちらの走らせ方も Tools/golden/sfz_runner.mjs（Node に頼らない）に置いてある。

import crypto from 'node:crypto';
import { b64, expectedFor } from './sfz_runner.mjs';

export { expectedFor };
const encoder = new TextEncoder();


export function wav({ channels, rate, frames, seed, smpl }) {
    const data = new DataView(new ArrayBuffer(frames * channels * 2));
    let state = seed >>> 0;
    for (let i = 0; i < frames * channels; i++) {
        state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
        data.setInt16(i * 2, (state >>> 16) - 32768 >> 1, true);
    }
    // smpl（ループ 1 つ）は data の後ろ。data と fmt の位置は変えない（試験の decode が固定の位置を読む）
    const tail = smpl ? 8 + 60 : 0;
    const bytes = new Uint8Array(44 + data.byteLength + tail);
    const view = new DataView(bytes.buffer);
    bytes.set(encoder.encode('RIFF'), 0);
    view.setUint32(4, 36 + data.byteLength + tail, true);
    bytes.set(encoder.encode('WAVEfmt '), 8);
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, channels, true);
    view.setUint32(24, rate, true);
    view.setUint32(28, rate * channels * 2, true);
    view.setUint16(32, channels * 2, true);
    view.setUint16(34, 16, true);
    bytes.set(encoder.encode('data'), 36);
    view.setUint32(40, data.byteLength, true);
    bytes.set(new Uint8Array(data.buffer), 44);
    if (smpl) {
        const at = 44 + data.byteLength;
        bytes.set(encoder.encode('smpl'), at);
        view.setUint32(at + 4, 60, true);
        const body = at + 8;
        view.setUint32(body + 12, 60, true);          // MIDI unity note
        view.setUint32(body + 28, 1, true);           // ループの数
        view.setUint32(body + 40, smpl.type, true);   // 0 forward / 1 alternate / 2 backward
        view.setUint32(body + 44, smpl.start, true);
        view.setUint32(body + 48, smpl.end, true);
        view.setUint32(body + 56, smpl.plays, true);
    }
    return bytes;
}


export const fixtureSpecs = {
    'a.wav': { channels: 1, rate: 48000, frames: 600, seed: 1 },
    'b one.wav': { channels: 2, rate: 44100, frames: 500, seed: 2 },
    'c.wav': { channels: 1, rate: 48000, frames: 300, seed: 3 },
    'samples/d.wav': { channels: 2, rate: 48000, frames: 400, seed: 4 },
    'samples/e.wav': { channels: 1, rate: 22050, frames: 250, seed: 5 },
    'x.wav': { channels: 1, rate: 48000, frames: 100, seed: 6 },
    'sfz/c.wav': { channels: 1, rate: 48000, frames: 200, seed: 7 },
    'samples/f.wav': { channels: 2, rate: 48000, frames: 600, seed: 8 },
    'samples/g.wav': { channels: 1, rate: 44100, frames: 300, seed: 9 },
    // 2.17.0: smpl のループ（forward / alternate・再生回数つき）
    'loop.wav': { channels: 1, rate: 48000, frames: 400, seed: 10, smpl: { type: 0, start: 20, end: 300, plays: 0 } },
    'loop2.wav': { channels: 2, rate: 44100, frames: 400, seed: 11, smpl: { type: 1, start: 8, end: 200, plays: 3 } },
    'ir.wav': { channels: 1, rate: 48000, frames: 64, seed: 12 },
    'three.wav': { channels: 3, rate: 48000, frames: 50, seed: 13 }
};

export function makeAudio() {
    const audio = Object.fromEntries(Object.entries(fixtureSpecs).map(([name, spec]) => [name, wav(spec)]));
    // 絵のファイル（中身は読まれない。バイト列がバンクへ入ること・Blob になることだけを見る）
    audio['img/pic.png'] = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4, 5, 6, 7, 8]);
    return audio;
}


// 埋め込み <sample>。公開されたバイトの表（sfzformat.com/headers/sample）
function encodePayload(bytes) {
    const out = [];
    for (const byte of bytes) {
        const mapped = (byte + 42) & 255;
        if ([61, 0, 9, 10, 13, 36].includes(mapped)) out.push(61, (byte + 64) & 255);
        else out.push(mapped);
    }
    return Uint8Array.from([...out, 36]);
}

// 本文のバイト列（UTF-8 でない部分を含む）
function embeddedSource(prefix, name, payload) {
    return Uint8Array.from([...encoder.encode(`${prefix}\n<sample> name=${name} data=`), ...encodePayload(payload)]);
}

// 同じものを 1 文字 1 バイトの文字列に（パーサの readText 用）
const latin1 = bytes => Array.from(bytes, byte => String.fromCharCode(byte)).join('');


export function parserInputs(audio) {
    const md5 = name => crypto.createHash('md5').update(audio[name]).digest('hex');
    const text = {
        basic: `<global> volume=-3 // comment
<group> lovel=1 hivel=64
<region> sample=a.wav key=c4
<region> sample="b one.wav" lokey=d4 hikey=e4 loop_mode=loop_continuous loop_start=10 loop_end=2000 ampeg_release=0.5
/* block
comment */ <group> lovel=65 hivel=127 seq_length=2 seq_position=2
<region> sample=c.wav lokey=c#3 hikey=db4 pitch_keycenter=e3 tune=-12 pan=25.5
`,
        defines: `#define $NAME a.wav
#define $LO 60
<region> sample=$NAME lokey=$LO hikey=62
<region> sample=$OTHER lokey=65 hikey=65
#include "inc/more.sfz"
`,
        include: `// first
<region> sample=c.wav key=48`,
        'inc/more.sfz': `#define $OTHER c.wav
<control> default_path=samples\\
<region> sample=d.wav key=72 offset=5 end=200 loop_mode=one_shot loop_start=500 loop_end=100
`,
        control: `<control>
set_cc1=64
set_cc7=90
default_path=samples/
<global> hicc7=100
<group> locc1=70
<region> sample=d.wav key=60
<group> locc1=60 hicc1=70
<region> sample=d.wav key=61
<region> sample=e.wav key=62 trigger=release
<region> sample=e.wav key=63 trigger=attack
<region> sample=e.wav key=64 sw_last=c2
<region> sample=e.wav key=65 sw_last=c2 sw_default=c2
`,
        invalid: `<region> sample=a.wav lokey=200 hikey=210
<region> sample=a.wav key=60 seq_length=2 seq_position=3
<region> sample=a.wav key=61 loop_mode=bogus
<region> sample=a.wav key=62.5
<region> sample=a.wav key=63 pitch_keytrack=5000
<region> sample=a.wav key=64
<region> key=65
<region> sample=nowhere.wav key=66
<region> sample=a.wav key=67 cutoff=100 fil_type=lpf_2p
`,
        spaces: `<region> sample=b one.wav key=60   lovel=0   hivel=100 amp_veltrack=-50
<region> sample="samples/d.wav" key=61
<region> sample=samples/../samples/e.wav key=62 transpose=-2 volume=6.5
`,
        groups: `<global> pan=10
<master> pan=20
<group> pan=30
<region> sample=a.wav key=60
<region> sample=a.wav key=61 pan=-5
<group>
<region> sample=a.wav key=62
<master> volume=-1
<region> sample=a.wav key=63
<global>
<region> sample=a.wav key=64
`,
        recursive: '#include "recursive.sfz"\n<region> sample=a.wav key=60',
        escape: '<region> sample=../outside.wav key=60',
        absolute: '#include "/etc/passwd"',
        missingInclude: '#include "nothing.sfz"',
        // 2.14.0: ファイルの代わりに作る音・エンベロープの時間を収める・sw_lolast / sw_hilast。
        generators: `<region> sample=*sine key=60 ampeg_release=250
<region> sample=*noise key=61 ampeg_attack=-3 loop_mode=no_loop pitch_keycenter=70
<region> sample=*saw key=62 ampeg_decay=abc
<region> sample=*silence key=63
<region> sample=a.wav key=64 ampeg_hold=100.5
`,
        switchRange: `<control> set_cc1=10
<global> sw_default=c3
<region> sample=a.wav key=60 sw_lolast=c2 sw_hilast=c4
<region> sample=a.wav key=61 sw_lolast=d3
<region> sample=a.wav key=62 sw_hilast=b2
<region> sample=a.wav key=63 sw_lolast=200
<region> sample=a.wav key=64 sustain_sw=on sostenuto_sw=on
`,
        // 2.17.0（0.17.0）で足された入力。
        conditions: `<global> locc1=10 hicc1=90 lochanaft=5 hichanaft=100 lopolyaft=1 hipolyaft=90
<group> loprog=0 hiprog=10 lochan=2 hichan=5 lobend=-100 hibend=100
<region> sample=a.wav key=60
<region> sample=a.wav key=61 locc64=1 hicc64=127 locc1=20
<region> sample=a.wav key=62 lochan=7 hichan=3
<region> sample=a.wav key=63 locc2=100 hicc2=50
`,
        triggers: ['attack', 'release', 'release_key', 'first', 'legato', 'bogus']
            .map((value, i) => `<region> sample=a.wav key=${60 + i} trigger=${value}`).join('\n'),
        aliases: `<control> set_realcc1=0.5 set_hdcc2=0.25 set_cc3=10
<region> sample=a.wav key=60 loopmode=loop_continuous loopstart=10 loopend=200 loopcount=2 amp_attack=0.1 amp_release=0.3
<region> sample=a.wav key=61 pitch=5 offby=3 polyphony_group=2 tune_keytrack=50 filtype=lpf_1p bendup=300 benddown=-100
<region> sample=a.wav key=62 gain_cc7=-6 pan_cc10=50 cutoff_cc74=1200 volume_oncc11=3 amp_vel2=1
`,
        hdcc: `<control> set_hdcc4=0.5 set_realcc9=1 set_cc2=10
<region> sample=a.wav key=60
<control> set_hdcc3=0.123456
<region> sample=c.wav key=61
`,
        hdccBad: '<control> set_hdcc1=1.1\n<region> sample=a.wav key=60',
        offsetPercent: `<region> sample=a.wav key=60 offset_mode=percent offset=25.5
<region> sample=a.wav key=61 offset=25.5
<region> sample=a.wav key=62 offset_mode=percent offset=100
`,
        endMinusOne: `<region> sample=a.wav key=60 end=-1
<region> sample=a.wav key=61 end=-1 md5=${md5('a.wav')}
<region> sample=a.wav key=62 end=100
`,
        md5: `<region> sample=a.wav key=60 md5=${md5('a.wav')}
<region> sample=c.wav key=61 md5=null
<region> sample=*sine key=62 md5=${md5('c.wav')}
`,
        md5Bad: '<region> sample=a.wav key=60 md5=xyz',
        curve: `<curve> curve_index=7 v000=0 v127=1
<curve> curve_index=8 v000=1 v064=0.25 v127=0
<region> sample=a.wav key=60 volume_oncc1=6 volume_curvecc1=7 pitch_oncc2=100 pitch_smoothcc2=20 pitch_stepcc2=1
<region> sample=a.wav key=61 pitcheg_depth=1200 pitcheg_attack=.2 fileg_depth=-2400 fillfo_freq=4 fillfo_depth=200 direction=reverse loop_count=3 loop_crossfade=.01
`,
        effects: `<region> sample=a.wav key=60 effect1=25 output=2
<region> sample=a.wav key=61 effect4=100
<effect> type=gain gain=-6 gain_oncc7=12 directtomain=50
<effect> type=filter bus=fx1 filter_type=lpf_2p filter_cutoff=2000 fx1tomain=25
<effect> type=rectify rectify=100 rectify_mode=half
<effect> type=gate gate_hold=.1
`,
        effectsBad: '<region> sample=a.wav key=60\n<effect> type=nosuch',
        effectImpulse: '<region> sample=a.wav key=60\n<control> default_path=samples/\n<effect> type=tdfir tdfir_impulse=e.wav tdfir_wet=50',
        effectImpulseMissing: '<region> sample=a.wav key=60\n<effect> type=tdfir tdfir_impulse=ghost.wav',
        script: '<global> script=scripts/s.txt\n<region> sample=a.wav key=60',
        scriptMissing: '<global> script=scripts/none.txt\n<region> sample=a.wav key=60',
        labels: `<control> image=img/pic.png label_key60=Middle C label_cc1=Vibrato label_output0=Main group_label=Pad
hint_ram_based=1 label_cc1=Modulation
<global> global_label=G sw_lokey=24 sw_hikey=36
<master> master_label=M
<region> sample=a.wav key=60 region_label=R sw_last=24 sw_label=Soft
`,
        labelBad: '<control> label_key128=Outside\n<region> sample=a.wav key=60',
        imageEscape: '<control> image=../../escape.png\n<region> sample=a.wav key=60',
        loopEndOffset: '<control> loop_end_offset=-1\n<region> sample=loop.wav key=60',
        loopEndOffsetBad: '<control> loop_end_offset=2\n<region> sample=loop.wav key=60',
        loopEndOffsetRegion: '<region> sample=loop.wav key=60 loop_end_offset=-1',
        embedded: latin1(embeddedSource('<region> sample=emb.wav key=60\n<region> sample=other.wav key=61', 'emb.wav', audio['x.wav'])),
        embeddedBytes: latin1(embeddedSource('<region> sample=embedded.wav', 'embedded.wav', Uint8Array.from({ length: 256 }, (_, i) => i))),
        embeddedIncomplete: '<region> sample=a.wav key=60\n<sample> name=a.wav data=|spp',
        embeddedDuplicate: latin1(Uint8Array.from([...embeddedSource('<region> sample=e.wav key=60', 'e.wav', audio['x.wav']),
            ...embeddedSource('', 'e.wav', audio['x.wav'])])),
        unsupported: '<region> sample=a.wav key=60 unknown_opcode=1 rt_decay=3 <fake> sample=a.wav key=61',
        envelopeBad: '<region> sample=a.wav key=60 ampeg_attack=-3 ampeg_release=250 ampeg_decay=abc'
    };
    // resolve: 'identity' = md5 が付いた領域の標本を、中身を見ずにそのまま返す（上流の resolveSample の代わり）
    const cases = [
        { name: 'basic', files: { 'basic.sfz': text.basic }, selected: 'basic.sfz' },
        { name: 'defines-include', files: { 'defines.sfz': text.defines, 'inc/more.sfz': text['inc/more.sfz'] }, selected: 'defines.sfz' },
        { name: 'control', files: { 'control.sfz': text.control }, selected: 'control.sfz' },
        { name: 'invalid', files: { 'invalid.sfz': text.invalid }, selected: 'invalid.sfz' },
        { name: 'spaces', files: { 'spaces.sfz': text.spaces }, selected: 'spaces.sfz' },
        { name: 'groups', files: { 'groups.sfz': text.groups }, selected: 'groups.sfz' },
        { name: 'in-folder', files: { 'sfz/inst.sfz': text.include }, selected: 'sfz/inst.sfz' },
        { name: 'recursive', files: { 'recursive.sfz': text.recursive }, selected: 'recursive.sfz' },
        { name: 'escape', files: { 'escape.sfz': text.escape }, selected: 'escape.sfz' },
        { name: 'absolute', files: { 'absolute.sfz': text.absolute }, selected: 'absolute.sfz' },
        { name: 'missing-include', files: { 'missing.sfz': text.missingInclude }, selected: 'missing.sfz' },
        { name: 'too-large', files: { 'big.sfz': '<region> sample=a.wav key=60 '.repeat(40) }, selected: 'big.sfz', maxBytes: 200 },
        { name: 'generators', files: { 'gen.sfz': text.generators }, selected: 'gen.sfz' },
        { name: 'switch-range', files: { 'sw.sfz': text.switchRange }, selected: 'sw.sfz' },
        { name: 'conditions', files: { 'c.sfz': text.conditions }, selected: 'c.sfz' },
        { name: 'triggers', files: { 't.sfz': text.triggers }, selected: 't.sfz' },
        { name: 'aliases', files: { 'al.sfz': text.aliases }, selected: 'al.sfz' },
        { name: 'hdcc', files: { 'h.sfz': text.hdcc }, selected: 'h.sfz' },
        { name: 'hdcc-out-of-range', files: { 'h.sfz': text.hdccBad }, selected: 'h.sfz' },
        { name: 'offset-percent', files: { 'o.sfz': text.offsetPercent }, selected: 'o.sfz' },
        { name: 'end-minus-one', files: { 'e.sfz': text.endMinusOne }, selected: 'e.sfz', resolve: 'identity' },
        { name: 'md5', files: { 'm.sfz': text.md5 }, selected: 'm.sfz', resolve: 'identity' },
        { name: 'md5-without-resolver', files: { 'm.sfz': text.md5 }, selected: 'm.sfz' },
        { name: 'md5-invalid', files: { 'm.sfz': text.md5Bad }, selected: 'm.sfz', resolve: 'identity' },
        { name: 'curve-and-modulation', files: { 'cu.sfz': text.curve }, selected: 'cu.sfz' },
        { name: 'effects', files: { 'fx.sfz': text.effects }, selected: 'fx.sfz' },
        { name: 'effects-invalid', files: { 'fx.sfz': text.effectsBad }, selected: 'fx.sfz' },
        { name: 'effect-impulse', files: { 'fx.sfz': text.effectImpulse }, selected: 'fx.sfz' },
        { name: 'effect-impulse-missing', files: { 'fx.sfz': text.effectImpulseMissing }, selected: 'fx.sfz' },
        { name: 'script', files: { 's.sfz': text.script, 'scripts/s.txt': 'on note message(1) end on' }, selected: 's.sfz' },
        { name: 'script-missing', files: { 's.sfz': text.scriptMissing }, selected: 's.sfz' },
        { name: 'labels-and-image', files: { 'l.sfz': text.labels }, selected: 'l.sfz' },
        { name: 'label-out-of-range', files: { 'l.sfz': text.labelBad }, selected: 'l.sfz' },
        { name: 'image-escapes-folder', files: { 'l.sfz': text.imageEscape }, selected: 'l.sfz' },
        { name: 'loop-end-offset', files: { 'lo.sfz': text.loopEndOffset }, selected: 'lo.sfz' },
        { name: 'loop-end-offset-invalid', files: { 'lo.sfz': text.loopEndOffsetBad }, selected: 'lo.sfz' },
        { name: 'loop-end-offset-in-region', files: { 'lo.sfz': text.loopEndOffsetRegion }, selected: 'lo.sfz' },
        { name: 'embedded-sample', files: { 'em.sfz': text.embedded }, selected: 'em.sfz' },
        { name: 'embedded-byte-alphabet', files: { 'em.sfz': text.embeddedBytes }, selected: 'em.sfz' },
        { name: 'embedded-incomplete', files: { 'em.sfz': text.embeddedIncomplete }, selected: 'em.sfz' },
        { name: 'embedded-duplicate', files: { 'em.sfz': text.embeddedDuplicate }, selected: 'em.sfz' },
        { name: 'unsupported', files: { 'u.sfz': text.unsupported }, selected: 'u.sfz' },
        { name: 'envelope-times', files: { 'en.sfz': text.envelopeBad }, selected: 'en.sfz' },
        // ARIA の bank.xml が渡す defines
        { name: 'bank-defines', files: { 'b.sfz': '<region> sample=$dir/e.wav key=60' }, selected: 'b.sfz', defines: { $dir: 'samples' } }
    ];
    return cases;
}


export function bankInputs(audio) {
    const files = {
        'inst.sfz': { text: '<region> sample=a.wav key=60' },
        'a.wav': { b64: b64(audio['a.wav']) },
        'samples/é日本.wav': { b64: b64(audio['c.wav']) },
        'quote"back\\slash.txt': { text: 'x' }
    };
    const cases = [];
    for (const warnings of [[], [{ code: 'invalid-regions', count: 3 }, { code: 'loop-points-ignored', count: 1 }]]) {
        cases.push({ selectedPath: 'inst.sfz', files, warnings });
    }
    return cases;
}


export function badBankInputs(audio) {
    // 壊し方は入力（どのバイトをどう書き換えるか）で持つ
    const inst = '<region> sample=a.wav key=60';
    return [
        { name: 'magic', mutate: { offset: 0, value: 1 } },
        { name: 'version', mutate: { offset: 4, value: 2 } },
        { name: 'metadata-length', mutate: { offset: 8, value: 0x7fffffff } },
        { name: 'truncated', truncate: 3 },
        { name: 'unknown-warning', warnings: [{ code: 'no-such-code', count: 1 }] }
    ].map(item => ({ ...item, selectedPath: 'inst.sfz', files: { 'inst.sfz': { text: inst }, 'a.wav': { b64: b64(audio['a.wav']) } } }));
}


const region = (sample, extra = {}) => ({
    lokey: 0, hikey: 127, lovel: 1, hivel: 127, lorand: 0, hirand: 1, seq_length: 1, seq_position: 1,
    pitch_keycenter: 60, pitch_keytrack: 100, transpose: 0, tune: 0, volume: 0, pan: 0, amp_veltrack: 100,
    offset: 0, loop_mode: 0, loop_start: 0, ampeg_attack: 0, ampeg_hold: 0, ampeg_decay: 0,
    ampeg_sustain: 100, ampeg_release: 0.001, sample, seqGroup: 0, ...extra
});


export function assetInputs() {
    return [
        {
            name: 'two-samples',
            regions: [region('a.wav', { lokey: 48, hikey: 59, seqGroup: 0 }),
                region('b one.wav', { lokey: 60, hikey: 71, seqGroup: 3, loop_mode: 2, loop_start: 10, loop_end: 400, end: 450 }),
                region('a.wav', { lokey: 72, hikey: 84, seqGroup: 3, pan: -25.5, tune: 7, ampeg_release: 0.5 })],
            samples: ['a.wav', 'b one.wav']
        },
        { name: 'bad-loop-oneshot', regions: [region('c.wav', { loop_mode: 1, loop_start: 999, loop_end: 5 }), region('c.wav', { lokey: 1, hikey: 2, offset: 5000 })], samples: ['c.wav'] },
        { name: 'all-invalid', regions: [region('c.wav', { offset: 9999 })], samples: ['c.wav'] },
        { name: 'too-large', regions: [region('a.wav')], samples: ['a.wav'], maxBytes: 1000 },
        // 2.17.0: 最後の標本が空・オフセットが % の領域・グループの識別子は圧縮される
        { name: 'groups-and-offsets', regions: [region('a.wav', { group: 7, off_by: -3, opcodes: { offset_mode: 'percent' }, offset: 50 }),
            region('c.wav', { group: -3, off_by: 7, loop_mode: 2, loop_start: 5, loop_end: 100 })], samples: ['a.wav', 'c.wav'] },
        { name: 'needs-streaming', regions: [region('a.wav', { load_mode: 1 })], samples: ['a.wav'] },
        { name: 'no-regions', regions: [], samples: [] }
    ];
}


export function budgetInputs() {
    const regions = [
        region('a.wav', { lokey: 36, hikey: 59, lovel: 1, hivel: 63 }),
        region('a.wav', { lokey: 36, hikey: 59, lovel: 64, hivel: 127 }),
        region('b one.wav', { lokey: 60, hikey: 71, seqGroup: 1 }),
        region('c.wav', { lokey: 72, hikey: 84, seqGroup: 1, lovel: 1, hivel: 80 }),
        region('x.wav', { lokey: 72, hikey: 84, seqGroup: 2, lovel: 81, hivel: 127 })
    ];
    return { regions, definitionBytes: 100,
        cases: [1 << 20, 12000, 9400, 9000, 8700, 8000, 500].map(maxBytes => ({ maxBytes })) };
}


export function importInputs(audio) {
    const folder = Object.fromEntries(Object.entries(audio).map(([name, bytes]) => [name, { b64: b64(bytes) }]));
    const only = (...names) => Object.fromEntries(names.map(name => [name, folder[name]]));
    const text = value => ({ text: value });
    const piano = {
        'piano.sfz': text('<control> default_path=samples/\n<group> lovel=1 hivel=63\n<region> sample=d.wav lokey=36 hikey=47\n<region> sample=e.wav lokey=48 hikey=59\n<group> lovel=64 hivel=127\n<region> sample=f.wav lokey=36 hikey=47\n<region> sample=g.wav lokey=48 hikey=59 cutoff=200\n<region> sample=missing.wav lokey=60 hikey=61'),
        'other.sfz': text('<region> sample=samples/e.wav key=64'),
        ...only('samples/d.wav', 'samples/e.wav', 'samples/f.wav', 'samples/g.wav'),
        'notes.txt': text('unrelated')
    };
    const big = 256 * 1024 * 1024;
    const imp = (name, files, selected, extra = {}) => ({ name, folder: files, selected, maxBytes: extra.maxBytes ?? big, ...extra });
    const cases = [
        imp('plain', piano, 'piano.sfz'),
        imp('other', piano, 'other.sfz'),
        imp('limit-12000', piano, 'piano.sfz', { maxBytes: 12000 }),
        // 0.17 は領域を間引かない。収まらなければ too-large（ストリーミングできる host だけが救う）
        ...[16000, 14000, 13000, 12400, 10000, 600].map(limit => imp(`limit-${limit}`, piano, 'piano.sfz', { maxBytes: limit })),
        imp('no-regions', { 'empty.sfz': text('<region> sample=gone.wav key=60') }, 'empty.sfz'),
        // 2.14.0: ARIA の bank.xml
        imp('aria-bank', {
            'Garritan/Garritan.bank.xml': text('<?xml version="1.0"?>\n<AriaBank name="G">\n<AriaElement path="Programs/inst.sfz" />\n' +
                '<Define name="$sample_dir" value="$Banks/Garritan/Samples" />\n<Define name=\'$gain\' value="-3" />\n' +
                '<Define name="bad" value="1" />\n<Define name="$amp" value="a &amp; b" /></AriaBank>'),
            'Garritan/Programs/inst.sfz': text('<region> sample=$sample_dir/d.wav key=60 volume=$gain\n<region> sample=*tri key=61'),
            'Garritan/Samples/d.wav': folder['samples/d.wav'],
            'Other/Other.bank.xml': text('<AriaBank><AriaElement path="x.sfz" /><Define name="$sample_dir" value="nope" /></AriaBank>'),
            'Other/x.sfz': text('<region> sample=y.wav key=60')
        }, 'Garritan/Programs/inst.sfz'),
        imp('aria-unlisted', {
            'B/B.bank.xml': text('<AriaBank><Define name="$dir" value="Samples" /></AriaBank>'),
            'B/unlisted.sfz': text('<region> sample=$dir/e.wav key=60'),
            'B/Samples/e.wav': folder['samples/e.wav']
        }, 'B/unlisted.sfz'),
        // UTF-8 として読めない本文は windows-1252 で読む（é = 0xE9）
        imp('windows-1252', {
            'latin.sfz': { b64: b64(Uint8Array.from([...encoder.encode('<region> sample=caf'), 0xE9, ...encoder.encode('.wav key=60')])) },
            'café.wav': folder['samples/f.wav']
        }, 'latin.sfz'),
        imp('generators-only', { 'gen.sfz': text('<region> sample=*sine lokey=0 hikey=127\n<region> sample=*noise key=60') }, 'gen.sfz'),
        // ---- 2.17.0（0.17.0）----
        imp('cc-aftertouch-program', { 'i.sfz': text('<global> lochanaft=5 hichanaft=100 lopolyaft=1 hipolyaft=90\n<group> loprog=0 hiprog=10 lochan=2 hichan=5 lobend=-100 hibend=100\n<region> sample=a.wav key=60 locc1=10 hicc1=90\n<region> sample=a.wav key=61 locc64=1 hicc64=127\n<region> sample=a.wav key=62 volume_oncc7=6'), ...only('a.wav') }, 'i.sfz'),
        imp('trigger-all', { 'i.sfz': text(['attack', 'release', 'release_key', 'first', 'legato'].map((value, i) => `<region> sample=a.wav key=${60 + i} trigger=${value}`).join('\n')), ...only('a.wav') }, 'i.sfz'),
        imp('aliases-and-hdcc', { 'i.sfz': text('<control> set_hdcc1=0.5 set_realcc2=0.25 set_cc3=10\n<region> sample=a.wav key=60 loopmode=loop_continuous loopstart=10 loopend=200 amp_attack=0.1 offby=3 polyphony_group=2\n<region> sample=a.wav key=61 pitch=5 tune_keytrack=50 filtype=lpf_1p bendup=300 gain_cc7=-6 cutoff_cc74=1200'), ...only('a.wav') }, 'i.sfz'),
        imp('offset-percent', { 'i.sfz': text('<region> sample=a.wav key=60 offset_mode=percent offset=25.5\n<region> sample=a.wav key=61 offset=25.5\n<region> sample=a.wav key=62 offset_mode=percent offset=100'), ...only('a.wav') }, 'i.sfz'),
        imp('end-minus-one', { 'i.sfz': text('<region> sample=a.wav key=60 end=-1\n<region> sample=a.wav key=61 end=100'), ...only('a.wav') }, 'i.sfz'),
        imp('md5-match', { 'i.sfz': text(`<region> sample=a.wav key=60 md5=${crypto.createHash('md5').update(audio['a.wav']).digest('hex')}`), ...only('a.wav', 'c.wav') }, 'i.sfz'),
        // 名前の標本が違っても、中身の md5 が合う別の標本を探して使う
        imp('md5-renamed', { 'i.sfz': text(`<region> sample=gone.wav key=60 md5=${crypto.createHash('md5').update(audio['c.wav']).digest('hex')}`), ...only('a.wav', 'c.wav') }, 'i.sfz'),
        imp('md5-no-match', { 'i.sfz': text('<region> sample=a.wav key=60 md5=00000000000000000000000000000000'), ...only('a.wav', 'c.wav') }, 'i.sfz'),
        imp('md5-invalid', { 'i.sfz': text('<region> sample=a.wav key=60 md5=xyz'), ...only('a.wav') }, 'i.sfz'),
        imp('embedded-sample', { 'i.sfz': { b64: b64(embeddedSource('<region> sample=emb.wav key=60 loop_mode=loop_continuous', 'emb.wav', audio['loop.wav'])) } }, 'i.sfz'),
        imp('curve-and-modulation', { 'i.sfz': text('<curve> curve_index=7 v000=0 v127=1\n<region> sample=a.wav key=60 volume_oncc1=6 volume_curvecc1=7 pitch_oncc2=100 pitch_smoothcc2=20\n<region> sample=a.wav key=61 pitcheg_depth=1200 pitcheg_attack=.2 fileg_depth=-2400 fillfo_freq=4 fillfo_depth=200 direction=reverse loop_count=3 loop_crossfade=.01'), ...only('a.wav') }, 'i.sfz'),
        imp('effects', { 'i.sfz': text('<region> sample=a.wav key=60 effect1=25 output=0\n<region> sample=a.wav key=61 effect4=100\n<effect> type=gain gain=-6 gain_oncc7=12 directtomain=50\n<effect> type=filter bus=fx1 filter_type=lpf_2p filter_cutoff=2000 fx1tomain=25\n<effect> type=rectify rectify=100 rectify_mode=half\n<effect> type=gate gate_hold=.1'), ...only('a.wav') }, 'i.sfz'),
        imp('effect-impulse', { 'i.sfz': text('<region> sample=a.wav key=60 effect1=100\n<effect> type=tdfir tdfir_impulse=ir.wav tdfir_wet=50'), ...only('a.wav', 'ir.wav') }, 'i.sfz'),
        imp('effect-impulse-missing', { 'i.sfz': text('<region> sample=a.wav key=60\n<effect> type=tdfir tdfir_impulse=ghost.wav'), ...only('a.wav') }, 'i.sfz'),
        imp('script', { 'i.sfz': text('<global> script=scripts/s.txt\n<region> sample=a.wav key=60'), 'scripts/s.txt': text('on note message(1) end on'), ...only('a.wav') }, 'i.sfz'),
        imp('script-invalid', { 'i.sfz': text('<global> script=s.txt\n<region> sample=a.wav key=60'), 's.txt': text('on init declare $n := message(1) end on'), ...only('a.wav') }, 'i.sfz'),
        imp('labels-and-image', { 'i.sfz': text('<control> image=img/pic.png label_key60=Middle C label_cc1=Vibrato group_label=Pad\n<global> sw_lokey=24 sw_hikey=36\n<region> sample=a.wav key=60 region_label=R sw_last=24 sw_label=Soft'), ...only('a.wav', 'img/pic.png') }, 'i.sfz'),
        imp('image-missing', { 'i.sfz': text('<control> image=img/none.png\n<region> sample=a.wav key=60'), ...only('a.wav') }, 'i.sfz'),
        imp('loop-end-offset', { 'i.sfz': text('<control> loop_end_offset=-1\n<region> sample=loop.wav key=60\n<region> sample=loop2.wav key=61\n<region> sample=loop.wav key=62 loop_mode=no_loop'), ...only('loop.wav', 'loop2.wav') }, 'i.sfz'),
        imp('wav-smpl-loop', { 'i.sfz': text('<region> sample=loop.wav key=60\n<region> sample=loop2.wav key=61 loop_start=4'), ...only('loop.wav', 'loop2.wav') }, 'i.sfz'),
        imp('wav-smpl-truncated', { 'i.sfz': text('<region> sample=bad.wav key=60'), 'bad.wav': { b64: b64(audio['a.wav'].subarray(0, 40)) } }, 'i.sfz'),
        imp('load-opcodes-need-streaming', { 'i.sfz': text('<region> sample=a.wav key=60 load_mode=1 load_start=10 load_end=300'), ...only('a.wav') }, 'i.sfz'),
        imp('soundfont-needs-streaming-host', { 'i.sf2': { b64: b64(encoder.encode('RIFF')) } }, 'i.sf2'),
        imp('three-channel-sample', { 'i.sfz': text('<region> sample=three.wav key=60'), ...only('three.wav') }, 'i.sfz')
    ].map(item => ({ ...item, context: true }));
    // 取り込みに失敗するものは、中身の再読み込みを見ない
    const streamed = [
        imp('streamed-load-opcodes', { 'i.sfz': text('<region> sample=a.wav key=60 load_mode=1 load_start=10 load_end=300\n<region> sample=c.wav key=61'), ...only('a.wav', 'c.wav') }, 'i.sfz', { streamHost: true }),
        imp('streamed-over-budget', piano, 'piano.sfz', { streamHost: true, maxBytes: 6000 }),
        imp('streamed-fits', piano, 'piano.sfz', { streamHost: true }),
        imp('streamed-effects', { 'i.sfz': text('<region> sample=a.wav key=60 effect1=50 load_mode=0\n<effect> type=gain gain=-6\n<effect> type=tdfir tdfir_impulse=ir.wav'), ...only('a.wav', 'ir.wav') }, 'i.sfz', { streamHost: true }),
        imp('streamed-generators', { 'i.sfz': text('<region> sample=*sine key=60 load_mode=1\n<region> sample=a.wav key=61'), ...only('a.wav') }, 'i.sfz', { streamHost: true }),
        imp('streamed-too-large-even-streamed', piano, 'piano.sfz', { streamHost: true, maxBytes: 600 })
    ].map(item => ({ ...item, context: true }));
    return { plain: cases, streamed };
}

// legacy は Tests/Fixtures/SFZ/legacy-banks.json（0.16 のころの見本が作った入れ物。縮めたもの（reduced-bank）を含む）

export function migrationInputs(legacy) {
    return legacy.banks.map(item => ({ name: item.name, container: item.container, entry: item.entry }));
}


export function folderInputs() {
    return { paths: ['root/a.sfz', 'root/b/c.SFZ', 'root/d.wav', 'root/b/e.sfz', 'root/f.sf2', 'root/g/h.SF3', 'root/i.sf2.txt'] };
}


export function normalizeInputs() {
    return [
        ...['a/b.sfz', 'a\\b\\c.sfz', './x//y', 'a/../b', 'a/../../b', '/abs', 'C:/x', 'a/./b/.'].map(input => ({ input })),
        ...['../x.wav', 'y/../../z', 'k.wav'].map(input => ({ input, directory: 'sub/dir' }))
    ];
}


// golden = 見本の入力（audio と各節の入力）。答えを作る側は expected を書き、確かめる側は答えと比べる。
export function buildInputs(legacy) {
    const audio = makeAudio();
    const imports = importInputs(audio);
    return {
        audio,
        sections: {
            parser: parserInputs(audio),
            bank: bankInputs(audio),
            badBanks: badBankInputs(audio),
            asset: assetInputs(),
            budget: budgetInputs(),
            imports: imports.plain,
            streamedImports: imports.streamed,
            migration: migrationInputs(legacy),
            folder: folderInputs(),
            normalize: normalizeInputs()
        }
    };
}
