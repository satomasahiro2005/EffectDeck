// node site/tools/guide-shots.mjs <撮った PNG の置き場>
//
// ガイドの枠に入れる画像を作る。撮影は iPhone のシミュレータ。
//   <置き場>/<id>.png → public/shots/<id>.webp（縦長の画面は幅 552 に縮める。README の 3 枚と同じ大きさ）
//   カードの絵（card-<slug>）は、下の CARDS の画面の上の方を 16:10 で切り出す
//   <置き場>/<id>.png → public/shots/full/<id>.webp（押して大きく開いたときの版。幅 1000）
//   src/shots.js       public/shots にある id の一覧。worker.js はここに載っている枠だけ本物の画像にする
//
// public/ は Workers の静的アセット（wrangler.toml の [assets]）。Worker に束ねないのは、
// 60 枚を超える画像で Worker の大きさの上限に近づくため。撮り直したらこれを走らせて、出力をコミットする。

import { readdirSync, mkdirSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join, basename } from "node:path";
import sharp from "sharp";

const src = process.argv[2];
if (!src) throw new Error("usage: node tools/guide-shots.mjs <dir of <id>.png>");
const here = (p) => fileURLToPath(new URL(`../${p}`, import.meta.url));
const OUT = here("public/shots");
const FULL = join(OUT, "full");
mkdirSync(FULL, { recursive: true });

// カードの絵の元。画面の上から何割のところを切るか（ツールバーの下から）。
const CARDS = {
  "card-connect": ["g-connect-3b", 0.28],
  "card-correction": ["g-correction-5", 0.1],
  "card-effects": ["g-effects-3", 0.06],
  "card-brir": ["g-brir-7", 0.08],
  "card-chatgpt": ["g-chatgpt-1", 0.4],
  "card-share": ["g-share-5", 0.62],
};

const pngs = readdirSync(src).filter((f) => /^[a-z0-9-]+\.png$/.test(f) && !f.startsWith("d-"));
for (const f of pngs) {
  const id = basename(f, ".png");
  const info = await sharp(join(src, f)).resize({ width: 552 }).webp({ quality: 80, effort: 6 }).toFile(join(OUT, `${id}.webp`));
  const full = await sharp(join(src, f)).resize({ width: 1000, withoutEnlargement: true }).webp({ quality: 82, effort: 6 }).toFile(join(FULL, `${id}.webp`));
  console.log(`${id}.webp`, info.width, info.height, info.size, "full", full.width, full.size);
}

for (const [card, [from, top]] of Object.entries(CARDS)) {
  const file = join(src, `${from}.png`);
  if (!existsSync(file)) continue;
  const meta = await sharp(file).metadata();
  const w = meta.width;
  const h = Math.round(w * 10 / 16);
  const y = Math.min(Math.round(meta.height * top), meta.height - h);
  const info = await sharp(file).extract({ left: 0, top: y, width: w, height: h })
    .resize({ width: 640 }).webp({ quality: 80, effort: 6 }).toFile(join(OUT, `${card}.webp`));
  console.log(`${card}.webp`, info.width, info.height, info.size);
}

const ids = readdirSync(OUT).filter((f) => f.endsWith(".webp")).map((f) => basename(f, ".webp")).sort();
writeFileSync(here("src/shots.js"),
  `// tools/guide-shots.mjs が書く。public/shots にある画像の id（手で直さない）。\n` +
  `export const GUIDE_SHOTS = new Set(${JSON.stringify(ids, null, 2)});\n`);
console.log(`${ids.length} shots`);
