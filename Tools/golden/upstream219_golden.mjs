// New host contracts in 2.19. Run against the clean HEAD pin, as other goldens.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath, pathToFileURL } from 'node:url';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const root = path.resolve(process.env.EFFETUNE_ROOT ?? path.join(repo, 'Vendor/effetune'));
const headphone = { window: {}, FirAssetEqPlugin: class {} };
vm.runInNewContext(fs.readFileSync(path.join(root, 'plugins/eq/headphone_eq.js'), 'utf8'), headphone);
const Headphone = headphone.window.HeadphoneEQPlugin;
const responseInputs = [
  { text: '\uFEFFfrequency,raw,error,target\r\n20,5,0,2\r\n200,1,0,0\r\n20000,-3,0,1', target: false },
  { text: 'frequency,raw,error,target\n20,5,0,2\n200,1,0,0\n20000,-3,0,1', target: true },
  { text: '# comment\n20 -1\n200 3\n20000 0', target: false },
  { text: 'frequency;raw;target\n20;;2\n200;0;1\n20000;-3;0', target: false },
  { text: '20 2\n20 7\n20000 -2', target: false },
  { text: '200 1\n300 2', target: false }
];
const responses = responseInputs.map(input => {
  try { return { ...input, expected: Headphone.parseResponseFile(input.text, input.target ? 'target' : 'measurement') }; }
  catch { return { ...input, expected: null }; }
});
const speaker = { window: {}, PluginBase: class {}, Float32Array, Uint32Array, ArrayBuffer };
vm.runInNewContext(fs.readFileSync(path.join(root, 'plugins/others/speaker_distortion_correction.js'), 'utf8')
  + '\nglobalThis.buildAsset = buildSpeakerCorrectionAsset;', speaker);
const { oddDecision } = await import(pathToFileURL(path.join(root, 'js/utils/measurement-dsp/speaker-distortion/check.js')));
const weights = (count, factor) => Float32Array.from({ length: count }, (_, i) => (i % 7 - 3) * factor);
const model = {
  recommendedLength: 'long',
  channels: [0, 1, 2, 3].map(index => ({
    index, label: `Speaker ${index + 1}`,
    weights: { short: index === 3 ? null : weights(1182, 0.0001 * (index + 1)), long: weights(1182, 0.0002 * (index + 1)) },
    on: { short: index === 0, long: index < 2 },
    reason: { short: index === 3 ? 'noFit' : null, long: null },
    odd: { weights: weights(32, 0.0003), bounds: Float32Array.from({ length: 32 }, () => 0.25),
      fitReason: index === 2 ? 'littleGain' : null,
      reason: { short: null, long: null, alone: null },
      on: { short: index === 0, long: index === 1, alone: index !== 2 } }
  }))
};
function portable(value) {
  if (value instanceof Float32Array) return { f32: Buffer.from(value.buffer, value.byteOffset, value.byteLength).toString('base64') };
  if (Array.isArray(value)) return value.map(portable);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, portable(v)]));
  return value;
}
const measurement = { id: 'fixture-219', name: 'Reference speakers', speakerModel: portable(model) };
const speakerAssets = [
  { fl: 'Short', cn: 0, co: 0, cn3: 0, co3: 0, outputChannels: 2 },
  { fl: 'Long', cn: 0, co: 0, cn3: 0, co3: 0, outputChannels: 4 },
  { fl: 'Short', cn: 15, co: 0, cn3: 15, co3: 0, outputChannels: 4 },
  { fl: 'Short', cn: 15, co: 15, cn3: 15, co3: 15, outputChannels: 4 },
  { fl: 'Long', cn: 0, co: 3, cn3: 0, co3: 0, outputChannels: 4 }
].map(({ outputChannels, ...settings }) => {
  const result = speaker.buildAsset(model, settings, outputChannels, oddDecision);
  if (result.error) throw Error(JSON.stringify(result.error));
  return { settings: Object.fromEntries(Object.entries(settings).map(([k, v]) => [k, String(v)])),
    outputChannels, payload: Buffer.from(result.payload).toString('base64') };
});
const out = path.join(repo, 'Tests/Fixtures/Upstream219/contracts.json');
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, JSON.stringify({ responses, measurement, speakerAssets }, null, 2) + '\n');
console.log(`${path.relative(repo, out)}: ${responses.length} response imports, ${speakerAssets.length} speaker assets`);
