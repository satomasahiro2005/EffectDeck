// node site/tools/og-guide.mjs
//
// ガイドの OGP（1200x630）を作る。/guide と /guide/<slug> がそれぞれ自分の絵を持つ。
//   public/og/guide.png         目次: 3 つのページの画面を並べる
//   public/og/guide-<slug>.png  各ページ: 左に Part と題、右にそのページの画面を 1 枚
// 画面は public/shots/full/<id>.webp（tools/guide-shots.mjs が作る）から取る。
// 字と色は og.png（tools/images.mjs）に合わせる。題や画面を替えたら走らせて、出力をコミットする。

import { mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import { GUIDE } from "../src/guide.js";

const here = (p) => fileURLToPath(new URL(`../${p}`, import.meta.url));
const OUT = here("public/og");
mkdirSync(OUT, { recursive: true });

const W = 1200;
const H = 630;
const BG = "#fafafa";
const MONO = "Cascadia Mono, Consolas, Menlo, monospace";
const SANS = "Segoe UI, Helvetica Neue, Arial, sans-serif";

// 各ページの代表の画面
const SHOT = {
  connect: "g-connect-3b",
  correction: "g-correction-4b",
  effects: "g-effects-3",
  brir: "g-brir-7",
  chatgpt: "g-chatgpt-1",
  share: "g-share-5",
};

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// 角を丸め、縁と影を付けた縦長の画面（og.png の phone と同じ作り。傾けない）。
async function phone(id, width) {
  const src = await sharp(here(`public/shots/full/${id}.webp`)).resize({ width }).toBuffer({ resolveWithObject: true });
  const { width: w, height: h } = src.info;
  const r = Math.round(w * 0.075);
  const mask = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="${w}" height="${h}" rx="${r}" fill="#fff"/></svg>`);
  const edge = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect x="1" y="1" width="${w - 2}" height="${h - 2}" rx="${r}" fill="none" stroke="#d1d9e0" stroke-width="2"/></svg>`);
  const rounded = await sharp(src.data).composite([{ input: mask, blend: "dest-in" }, { input: edge }]).png().toBuffer();
  const pad = 60;
  const shadow = await sharp({ create: { width: w + pad * 2, height: h + pad * 2, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
    .composite([{ input: Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="${w}" height="${h}" rx="${r}" fill="#1f2328" fill-opacity=".38"/></svg>`), left: pad, top: pad + 14 }])
    .png().toBuffer();
  const blurred = await sharp(shadow).blur(20).png().toBuffer();
  return { data: await sharp(blurred).composite([{ input: rounded, left: pad, top: pad }]).png().toBuffer(), pad };
}

// 題を幅で折る（字数の目安。等幅でないので少し余らせる）。
function wrap(text, max) {
  const lines = [];
  let line = "";
  for (const word of text.split(" ")) {
    if (line && (line + " " + word).length > max) { lines.push(line); line = word; } else line = line ? line + " " + word : word;
  }
  if (line) lines.push(line);
  return lines;
}

const icon = await sharp(here("../docs/icon.png")).resize(96).png().toBuffer();

// 大きな canvas に置いてから真ん中を切り出す（はみ出す画面を composite できないため）。
async function card(name, textSvg, phones) {
  const M = 800;
  const big = await sharp({ create: { width: W + 2 * M, height: H + 2 * M, channels: 3, background: BG } })
    .composite([
      ...phones.map((p) => ({ input: p.data, left: M + p.x - p.pad, top: M + p.y - p.pad })),
      { input: icon, left: M + 84, top: M + 84 },
      { input: textSvg, left: M, top: M },
    ])
    .png().toBuffer();
  const info = await sharp(big).extract({ left: M, top: M, width: W, height: H }).png({ compressionLevel: 9 }).toFile(`${OUT}/${name}`);
  console.log(name, info.width, info.height, info.size);
}

const svg = (inner) => Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">${inner}</svg>`);

// 各ページ
for (const [i, g] of GUIDE.pages.entries()) {
  const label = `Part ${i + 1}${g.tag ? ` · ${g.tag}` : ""}`;
  const lines = wrap(g.title, 20);
  const size = lines.length > 2 ? 50 : 58;
  const titleY = 330;
  const title = lines.map((l, k) => `<text x="84" y="${titleY + k * (size + 12)}" font-family="${MONO}" font-weight="600" font-size="${size}" fill="#1f1f1f" letter-spacing="-1">${esc(l)}</text>`).join("");
  const text = svg(`
  <text x="200" y="128" font-family="${MONO}" font-weight="600" font-size="34" fill="#1f1f1f">EffectDeck</text>
  <text x="200" y="166" font-family="${SANS}" font-size="26" fill="#656d76">Guide</text>
  <text x="84" y="${titleY - size - 26}" font-family="${MONO}" font-weight="600" font-size="24" fill="#2563eb">${esc(label)}</text>
  ${title}
  <text x="84" y="574" font-family="${SANS}" font-size="24" fill="#656d76">effectdeck.nemut.ai/guide/${g.slug}</text>`);
  const ph = await phone(SHOT[g.slug], 300);
  await card(`guide-${g.slug}.png`, text, [{ ...ph, x: 820, y: 56 }]);
}

// 目次: サイトの /guide と同じく 6 枚のカードを 3 列 2 段に並べる
{
  const M = 44, GAP = 16, TOP = 112;
  const CW = Math.floor((W - 2 * M - 2 * GAP) / 3); // カードの幅
  const IH = 168;                                   // カードの絵の高さ
  const CH = IH + 76;                               // カードの高さ（絵 + Part + 題）
  const layers = [];
  // 題は全部同じ大きさ。一番長い題がカードに収まる大きさにそろえる
  const short = (t) => (t.length > 30 ? t.replace(" inside your headphones", "…") : t);
  const TITLE_SIZE = Math.min(22, ...GUIDE.pages.map((g) => Math.floor((CW - 30) / (short(g.title).length * 0.56))));
  let texts = `
  <text x="${M + 62}" y="62" font-family="${MONO}" font-weight="600" font-size="34" fill="#1f1f1f">EffectDeck</text>
  <text x="${M + 300}" y="62" font-family="${SANS}" font-size="30" fill="#656d76">Guide</text>
  <text x="${W - M}" y="62" text-anchor="end" font-family="${SANS}" font-size="22" fill="#656d76">effectdeck.nemut.ai/guide</text>`;
  for (const [k, g] of GUIDE.pages.entries()) {
    const x = M + (k % 3) * (CW + GAP);
    const y = TOP + Math.floor(k / 3) * (CH + GAP);
    // カードの地と縁
    layers.push({ input: Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${CW}" height="${CH}"><rect x="1" y="1" width="${CW - 2}" height="${CH - 2}" rx="14" fill="#fff" stroke="#d1d9e0" stroke-width="2"/></svg>`), left: x, top: y });
    // 絵（card-<slug>.webp を上の角だけ丸めて）
    const iw = CW - 20;
    const img = await sharp(here(`public/shots/card-${g.slug}.webp`)).resize({ width: iw, height: IH - 10, fit: "cover", position: "top" }).png().toBuffer();
    const mask = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${iw}" height="${IH - 10}"><rect width="${iw}" height="${IH - 10}" rx="8" fill="#fff"/></svg>`);
    layers.push({ input: await sharp(img).composite([{ input: mask, blend: "dest-in" }]).png().toBuffer(), left: x + 10, top: y + 10 });
    const label = `Part ${k + 1}${g.tag ? ` · ${g.tag}` : ""}`;
    const title = short(g.title);
    texts += `
  <text x="${x + 14}" y="${y + IH + 26}" font-family="${MONO}" font-weight="600" font-size="17" fill="#2563eb">${esc(label)}</text>
  <text x="${x + 14}" y="${y + IH + 56}" font-family="${SANS}" font-weight="600" font-size="${TITLE_SIZE}" fill="#1f1f1f">${esc(title)}</text>`;
  }
  const small = await sharp(here("../docs/icon.png")).resize(48).png().toBuffer();
  const out = await sharp({ create: { width: W, height: H, channels: 3, background: BG } })
    .composite([...layers, { input: small, left: M, top: 26 }, { input: svg(texts), left: 0, top: 0 }])
    .png({ compressionLevel: 9 }).toFile(`${OUT}/guide.png`);
  console.log("guide.png", out.width, out.height, out.size);
}
