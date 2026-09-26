// node site/tools/images.mjs
//
// Builds the images the site serves from its own origin:
//   assets/shot-*.webp  from docs/shot-*.png (the README screenshots, 552x1200)
//   assets/og.png       1200x630 Open Graph card (icon, name, tagline, two screenshots)
//
// sharp comes in with miniflare/wrangler (site/node_modules). Re-run this when the
// screenshots or the icon in docs/ change, and commit the outputs.

import { fileURLToPath } from "node:url";
import sharp from "sharp";

const repo = (p) => fileURLToPath(new URL(`../../${p}`, import.meta.url));
const out = (p) => fileURLToPath(new URL(`../assets/${p}`, import.meta.url));

export const SHOTS = ["effects", "analyzers", "routing"];

for (const s of SHOTS) {
  const info = await sharp(repo(`docs/shot-${s}.png`))
    .webp({ quality: 82, effort: 6, smartSubsample: true })
    .toFile(out(`shot-${s}.webp`));
  console.log(`shot-${s}.webp`, info.width, info.height, info.size);
}

// MARK: - og.png

const W = 1200;
const H = 630;
const BG = "#fafafa";

// A screenshot with rounded corners, a 2px edge and a dark blurred shadow, tilted.
// The edge and the shadow keep the white screenshots apart from the #fafafa card.
async function phone(name, width, angle) {
  const src = await sharp(repo(`docs/shot-${name}.png`)).resize({ width }).toBuffer({ resolveWithObject: true });
  const { width: w, height: h } = src.info;
  const r = Math.round(w * 0.075);
  const mask = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="${w}" height="${h}" rx="${r}" fill="#fff"/></svg>`);
  const edge = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect x="1" y="1" width="${w - 2}" height="${h - 2}" rx="${r}" fill="none" stroke="#d1d9e0" stroke-width="2"/></svg>`);
  const rounded = await sharp(src.data)
    .composite([{ input: mask, blend: "dest-in" }, { input: edge }])
    .png()
    .toBuffer();
  const pad = 60;
  const shadow = await sharp({
    create: { width: w + pad * 2, height: h + pad * 2, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  })
    .composite([{
      input: Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="${w}" height="${h}" rx="${r}" fill="#1f2328" fill-opacity=".42"/></svg>`),
      left: pad, top: pad + 16,
    }])
    .png()
    .toBuffer();
  const blurred = await sharp(shadow).blur(20).png().toBuffer();
  const card = await sharp(blurred).composite([{ input: rounded, left: pad, top: pad }]).png().toBuffer();
  return sharp(card).rotate(angle, { background: { r: 0, g: 0, b: 0, alpha: 0 } }).png().toBuffer({ resolveWithObject: true });
}

// Both phones stay inside the card on the right; only the bottoms run off, on purpose.
const left = await phone("effects", 250, -6);
const right = await phone("analyzers", 250, 6);

const icon = await sharp(repo("docs/icon.png")).resize(132).png().toBuffer();

const text = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}">
  <text x="84" y="342" font-family="Cascadia Mono, Consolas, Menlo, monospace" font-weight="600" font-size="70" fill="#1f1f1f" letter-spacing="-1">EffectDeck</text>
  <text x="86" y="400" font-family="Segoe UI, Helvetica Neue, Arial, sans-serif" font-size="31" fill="#656d76">Audio effects for any app on iPhone</text>
  <text x="86" y="446" font-family="Segoe UI, Helvetica Neue, Arial, sans-serif" font-size="24" fill="#656d76">EffeTune's DSP · iOS 27 · effectdeck.nemut.ai</text>
</svg>`);

// sharp will not composite an overlay larger than the base, and the tilted phones run off
// the bottom edge. Compose on an oversized canvas, then cut the card out of the middle.
const M = 800;
const big = await sharp({ create: { width: W + 2 * M, height: H + 2 * M, channels: 3, background: BG } })
  .composite([
    { input: left.data, left: M + 600, top: M + 64 },
    { input: right.data, left: M + 770, top: M + 104 },
    { input: icon, left: M + 84, top: M + 140 },
    { input: text, left: M, top: M },
  ])
  .png()
  .toBuffer();
const og = await sharp(big)
  .extract({ left: M, top: M, width: W, height: H })
  .png({ compressionLevel: 9 })
  .toFile(out("og.png"));
console.log("og.png", og.width, og.height, og.size);
