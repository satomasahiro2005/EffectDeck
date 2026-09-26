// node site/test.mjs
//
// **test-vector.json はアプリ側の Tests/Unit/FXDLinkTests.swift と同じファイル。**
// 縮めた側でバイト列は変わるが、どちらの展開器でも同じソースに戻ることを両側で見る。
// 受ける範囲もアプリ（ETFXDLink.decode）と揃える。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import zlib from "node:zlib";
import { decodeFXD } from "./src/fxd.js";
import * as parse from "./src/parse.js";
import { DECK_HOST, APP_STORE, TESTFLIGHT, GITHUB, RELEASES, JSFX_MD } from "./src/links.js";
import { TEXT, FAQ, LLMS_TXT } from "./src/text.js";
import { homeLd, plainText } from "./src/seo.js";

const { chainEntries } = parse;

const here = new URL(".", import.meta.url);
const vector = JSON.parse(readFileSync(new URL("test-vector.json", here), "utf8"));
let n = 0;
const test = async (name, fn) => { await fn(); n++; console.log("ok -", name); };

await test("shared vector decodes to its source", async () => {
  assert.equal(await decodeFXD(vector.payload), vector.source);
  // アプリが作るのは effectdeck だけ（fxd は別名で 301 するだけ）。
  assert.equal(vector.url, `https://${DECK_HOST}/j#` + vector.payload);
  assert.equal(DECK_HOST, "effectdeck.nemut.ai");
  assert.equal(new URL(vector.url).hash.slice(1), vector.payload);
});

await test("a node-made payload decodes too (encoder bytes may differ)", async () => {
  const payload = zlib.deflateRawSync(Buffer.from(vector.source, "utf8"), { level: 0 }).toString("base64url"); // stored block
  assert.notEqual(payload, vector.payload);
  assert.equal(await decodeFXD(payload), vector.source);
});

await test("round trip through node zlib (deflateRaw + base64url)", async () => {
  const src = "desc:Round Trip\n// 日本語 é ✓\n@sample\nspl0 = spl0;\n".repeat(50);
  const payload = zlib.deflateRawSync(Buffer.from(src, "utf8")).toString("base64url");
  assert.ok(!/[=+/]/.test(payload));
  assert.equal(await decodeFXD(payload), src);
});

await test("rejects garbage", async () => {
  const bad = [
    "", "!!!!", "abc=", vector.payload + "+", "A",           // not base64url / impossible length
    vector.payload + "=",                                    // padded
    vector.payload.replace(/-/g, "+"),                        // plain base64 alphabet
    ` ${vector.payload}`,                                    // whitespace (the app rejects it too)
    zlib.deflateRawSync(Buffer.from(" \n\t")).toString("base64url"), // whitespace-only source
    Buffer.from("hello world").toString("base64url"),       // not deflate
    zlib.deflateSync(Buffer.from("desc:x")).toString("base64url"), // zlib-wrapped, not raw
    zlib.deflateRawSync(Buffer.from([0xff, 0xfe, 0x80])).toString("base64url"), // not UTF-8
    zlib.deflateRawSync(Buffer.alloc(0)).toString("base64url"), // empty
    vector.payload.slice(0, 20),                             // truncated stream
  ];
  for (const p of bad) await assert.rejects(decodeFXD(p), `accepted: ${JSON.stringify(p)}`);
  await assert.rejects(decodeFXD(undefined));
});

await test("size caps match the app (64 KB source, 96K-char payload)", async () => {
  const pack = (n) => zlib.deflateRawSync(Buffer.alloc(n, 0x61)).toString("base64url");
  assert.equal((await decodeFXD(pack(64 * 1024))).length, 64 * 1024);
  await assert.rejects(decodeFXD(pack(64 * 1024 + 1)), /too large/);
  await assert.rejects(decodeFXD(pack(10_000_000)), /too large/);   // bomb: small payload, huge output
  await assert.rejects(decodeFXD("A".repeat(96 * 1024 + 4)), /not base64url/);
});

await test("decoder is self-contained (it is embedded in the page by toString)", async () => {
  const embedded = new Function(`return (${decodeFXD.toString()});`)();
  assert.equal(await embedded(vector.payload), vector.source);
});

await test("no language negotiation is left", async () => {
  assert.equal(parse.pickLang, undefined);
  assert.deepEqual(Object.keys(TEXT).filter((k) => k === "en" || k === "ja"), []);
  // 文面に日本語が残っていない（仮名・漢字）
  const all = JSON.stringify({ TEXT, FAQ }) + LLMS_TXT;
  assert.ok(!/[\u3040-\u30ff\u4e00-\u9fff]/.test(all));
});

await test("JSON-LD: SoftwareApplication and a FAQPage that mirrors the FAQ", async () => {
  const ld = JSON.parse(JSON.stringify(homeLd()));
  assert.equal(ld["@context"], "https://schema.org");
  const app = ld["@graph"].find((x) => x["@type"] === "SoftwareApplication");
  assert.equal(app.name, "EffectDeck");
  assert.equal(app.operatingSystem, "iOS 27");
  assert.ok(app.applicationCategory);
  assert.deepEqual(app.offers, { "@type": "Offer", price: "0", priceCurrency: "USD" });
  assert.equal(app.isAccessibleForFree, true);
  assert.equal(app.license, "https://opensource.org/licenses/MIT");
  assert.match(app.description, /Free and open source \(MIT\)/);
  assert.equal(app.downloadUrl, APP_STORE);
  const faq = ld["@graph"].find((x) => x["@type"] === "FAQPage");
  assert.equal(faq.mainEntity.length, FAQ.length);
  faq.mainEntity.forEach((q, i) => {
    assert.equal(q["@type"], "Question");
    assert.equal(q.name, FAQ[i].q);
    assert.equal(q.acceptedAnswer.text, plainText(FAQ[i].a));
    assert.ok(!/[<>]/.test(q.acceptedAnswer.text), "answer text has tags");
  });
  assert.match(FAQ[0].q, /JamesDSP or ViPER4Android/);
  assert.match(plainText(FAQ[0].a), /iOS 27/);
  assert.match(plainText(FAQ[0].a), /Media Device Extension/);
  assert.match(plainText(FAQ[0].a), /Now Playing/);
  assert.match(plainText(FAQ[0].a), /Games are not covered/);
  assert.equal(plainText('a &amp; <a href="x">b</a> &lt;c&gt;'), "a & b <c>");
});

await test("llms.txt names the app and links README, JSFX.md, App Store, GitHub, release notes", async () => {
  assert.ok(LLMS_TXT.startsWith("# EffectDeck\n"));
  for (const u of [APP_STORE, GITHUB, GITHUB + "#readme", RELEASES, JSFX_MD]) assert.ok(LLMS_TXT.includes(u), u);
  assert.match(LLMS_TXT, /not affiliated with/);
  assert.match(LLMS_TXT, /free and open source \(MIT\)/);
  assert.ok(!/<[a-z]/i.test(LLMS_TXT), "HTML in llms.txt");
});

// リリースごとに変わること（TestFlight・ベータ・どのビルドに何があるか）はページに書かない（text.js の頭）。
// 例外はフッターの名札 betaLink 1 つだけ。
await test("no release status in the text: no TestFlight or beta outside the footer label", async () => {
  const release = /testflight|\bbeta\b|App Store version|build/i;
  for (const [k, v] of Object.entries(TEXT)) {
    if (k === "betaLink") continue;
    assert.ok(!release.test(JSON.stringify(v)), `TEXT.${k}: ${JSON.stringify(v)}`);
  }
  assert.equal(TEXT.betaLink, "Beta (TestFlight)");
  for (const f of FAQ) assert.ok(!release.test(f.q + f.a), f.q);
  assert.ok(!release.test(JSON.stringify(homeLd())), "JSON-LD");
  assert.ok(!release.test(LLMS_TXT), "llms.txt");
  assert.ok(!LLMS_TXT.includes(TESTFLIGHT));
  // JSFX は機能として書く
  assert.match(TEXT.jsfx[0], /^EffectDeck loads JSFX/);
  assert.ok(FAQ.some((f) => f.a.includes(JSFX_MD)), "FAQ links JSFX.md");
  assert.ok(FAQ.some((f) => /free and open source under the MIT license/.test(f.a)), "FAQ says FOSS");
});

await test("chain preview reads the share-link p", async () => {
  const chain = [
    { nm: "Section", cm: "Main", en: true },
    { nm: "Volume", en: true, vl: 0 },
    { nm: "Parametric EQ", en: false },
  ];
  const p = Buffer.from(JSON.stringify(chain)).toString("base64");
  assert.deepEqual(chainEntries(p), [
    { section: true, name: "Main Section" },
    { section: false, name: "Volume", off: false },
    { section: false, name: "Parametric EQ", off: true },
  ]);
  // URLSearchParams が生の + を空白にしたもの
  const plus = Buffer.from(JSON.stringify([{ nm: "Volume~" }])).toString("base64");
  assert.ok(plus.includes("+"));
  assert.deepEqual(chainEntries(plus.replace(/\+/g, " ")), [{ section: false, name: "Volume~", off: false }]);
  assert.equal(chainEntries("not base64 at all"), null);
  assert.equal(chainEntries(Buffer.from('{"nm":"x"}').toString("base64")), null);
});

console.log(`\n${n} passed`);
