// Tools/sfzjs/entry.mjs
// 上流 js/sfz・js/sf2 から EffectDeck が使うものだけを 1 つの名前空間（ETSFZ）に出す。
// ここに無いものはバンドルの外から呼べない（木ゆすりで落ちる）。足したら build.mjs --update-modules で
// modules.txt も直す。
//
// **このファイルは単体では解決できない。**build.mjs が上流（指している版）を一時置き場へ展開してパッチを当て、
// そこへこのファイルを写してから束ねる。./js/ は、その展開先の js/（= Vendor/effetune/js）を指す。

// --- SFZ: 読み取り・パック ---
export { parseSfz, normalizeSfzPath } from './js/sfz/parser.js';
export { packSfzAsset, packStreamedSfzAsset, SFZ_REGION_FIELDS } from './js/sfz/asset.js';
export { SfzLibraryService, prepareSfzSamples, selectSfzRegionsForBudget, mergeSfzWarnings, listSfzFolderFiles } from './js/sfz/service.js';
export { encodeSfzBank, decodeSfzBank, identifySfzBank } from './js/sfz/bank.js';

// --- SFZ: 流し込み（ストリーミング） ---
export { prepareStreamedSfzBank } from './js/sfz/streamed-bank.js';
export { attachSfzSampleStreamWorker } from './js/sfz/sample-stream-worker.js';

// --- 準備の幾何（チャンネル数・最大フレーム）と、確保量の照会に渡す制御部 ---
export { sfzPluginPreparationContext, sfzPreparationContext } from './js/sfz/preparation-context.js';
export { samplePlayerPreparationData } from './js/sfz/effect-cost.js';

// --- SoundFont ---
export { parseSf2 } from './js/sf2/parser.js';
export { compileSf2 } from './js/sf2/compiler.js';
export { openSf2Source } from './js/sf2/source.js';
export { prepareSoundFontBank, sf2SamplerRegions } from './js/sf2/asset.js';
export { packSf2Modulation } from './js/sf2/modulation.js';
