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
import { DECK_HOST, APP_STORE, TESTFLIGHT, GITHUB, RELEASES, JSFX_MD, CHAIN_MD, CHATGPT, CHATGPT_Q, OPENAI_PRIVACY, EMAIL } from "./src/links.js";
import { TEXT, FAQ, LLMS_TXT, PRIVACY } from "./src/text.js";
import { GUIDE } from "./src/guide.js";

// ガイドの 1 ページの字（block の字を全部つないだもの）
const guideText = (slug) => JSON.stringify(GUIDE.pages.find((g) => g.slug === slug).blocks);
const guideParas = (slug) => GUIDE.pages.find((g) => g.slug === slug).blocks.flatMap((b) => b.p ? [b.p] : b.ul ?? []);
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
  const all = JSON.stringify({ TEXT, FAQ, GUIDE }) + LLMS_TXT;
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
  // アプリのボタンの名札は機能の名前で、ビルドの話ではない。外してから見る。
  const label = (s) => s.replaceAll("Build with ChatGPT…", "");
  for (const [k, v] of Object.entries(TEXT)) {
    if (k === "betaLink") continue;
    assert.ok(!release.test(label(JSON.stringify(v))), `TEXT.${k}: ${JSON.stringify(v)}`);
  }
  assert.equal(TEXT.betaLink, "Beta (TestFlight)");
  assert.ok(!release.test(label(JSON.stringify(GUIDE))), "GUIDE");
  for (const f of FAQ) assert.ok(!release.test(f.q + f.a), f.q);
  assert.ok(!release.test(JSON.stringify(homeLd())), "JSON-LD");
  assert.ok(!release.test(label(LLMS_TXT)), "llms.txt");
  assert.ok(!LLMS_TXT.includes(TESTFLIGHT));
  // JSFX は機能として書く
  assert.ok(guideParas("chatgpt").some((p) => p.startsWith("EffectDeck loads JSFX")));
  assert.ok(FAQ.some((f) => f.a.includes(JSFX_MD)), "FAQ links JSFX.md");
  assert.ok(FAQ.some((f) => /free and open source under the MIT license/.test(f.a)), "FAQ says FOSS");
});

// /writeで見せる依頼文（links.jsの頭）。決め事はJSFX.mdにあり、依頼は短く保つ。
await test("/write text: a short request that points at JSFX.md, linked from the ChatGPT guide and llms.txt", async () => {
  assert.equal(decodeURIComponent(CHATGPT.slice("https://chatgpt.com/?q=".length)), CHATGPT_Q);
  assert.ok(CHATGPT_Q.startsWith("Write a JSFX effect for EffectDeck. First read "));
  assert.ok(CHATGPT_Q.includes(JSFX_MD));
  assert.ok(CHATGPT_Q.endsWith("Then ask me what effect I want."));
  assert.ok(CHATGPT_Q.length < 200, "long requests get cut off on the way into ChatGPT");
  assert.ok(!CHATGPT_Q.includes("@"), "no @ in the request");
  assert.ok(!/\s{2}|\n/.test(CHATGPT_Q), "joined lines");
  assert.equal(TEXT.writeTitle, "Write a JSFX effect with ChatGPT");
  assert.match(TEXT.writePlan, /^A paid ChatGPT plan is recommended/);
  assert.ok(TEXT.writePlan.includes(`href="${JSFX_MD}"`));
  assert.match(TEXT.writeReturn, /Import JSFX → From Files/);
  assert.match(TEXT.writeReturn, /From Clipboard/);
  assert.ok(guideText("chatgpt").includes('href=\\"/write\\"'));
  assert.ok(!JSON.stringify(GUIDE).includes("chatgpt.com"), "the site goes through /write");
  assert.ok(LLMS_TXT.includes("https://effectdeck.nemut.ai/write"));
});

// 鎖を組ませるCHAIN.md。JSFX.mdの隣に置き、llms.txtはページと同じことだけを書く（text.jsの頭）。
await test("CHAIN.md: linked next to JSFX.md in the ChatGPT guide and in llms.txt", async () => {
  assert.equal(CHAIN_MD, "https://github.com/satomasahiro2005/EffectDeck/blob/main/CHAIN.md");
  assert.ok(guideText("chatgpt").includes(`href=\\"${JSFX_MD}\\"`));
  const para = guideParas("chatgpt").find((p) => p.includes(CHAIN_MD) && p.includes("opens ChatGPT"));
  assert.ok(para, "the JSFX section says what CHAIN.md is for");
  assert.match(para, /Build with ChatGPT…/);
  assert.match(para, /Import from clipboard/);
  assert.ok(LLMS_TXT.includes(`- CHAIN.md: ${CHAIN_MD}`));
  assert.match(LLMS_TXT, /Build with ChatGPT… \(at the top of the effect list\)/);
  assert.match(LLMS_TXT, /Import from clipboard/);
});

// アプリの2つの口はchatgpt.comを直に開く（EffectPickerView.writeJSFX / buildChain、61efe19）。
// /writeはページ側の道で、アプリはそこを通らない。
await test("the app opens ChatGPT directly; the page still goes through /write", async () => {
  const para = guideParas("chatgpt").find((p) => p.includes("opens ChatGPT with a short request"));
  assert.match(para, /opens ChatGPT with a short request that points it at JSFX\.md/);
  assert.ok(!/opens a page/.test(JSON.stringify({ TEXT, GUIDE })), "the app no longer opens a page");
  const chain = guideParas("chatgpt").find((p) => p.includes(CHAIN_MD) && p.includes("opens ChatGPT"));
  assert.match(chain, /opens ChatGPT the same way/);
  assert.match(chain, /Tap the link it returns/);
  assert.match(LLMS_TXT, /Write JSFX with ChatGPT \(under Plugins\) opens ChatGPT/);
  assert.match(LLMS_TXT, /comes back as a link to tap/);
});

// 内蔵の効果だけの鎖はEffeTuneのWeb版のリンクになる（ETShareLink.url(for:)）。
await test("share links: effectdeck.nemut.ai only for JSFX and chains with AUv3 or JSFX", async () => {
  const share = guideParas("share");
  assert.ok(share.some((p) => /^JSFX scripts, and chains that use AUv3 plug-ins or JSFX effects, are shared as links on effectdeck\.nemut\.ai\./.test(p)));
  assert.ok(share.some((p) => /A chain of only built-in effects is shared as a link to the EffeTune web app/.test(p)));
  assert.match(LLMS_TXT, /A chain of only built-in effects is shared as a link to the EffeTune web app\./);
  assert.ok(!LLMS_TXT.includes("Chains and JSFX scripts are shared"));
});

// プライバシーポリシーのLinksは、アプリが取りに行く先と開く先を全部言う（text.jsのPRIVACYの頭）。
await test("privacy: Links covers every download and every page the app opens", async () => {
  const body = PRIVACY.body.replace(/\s+/g, " ");
  assert.equal(PRIVACY.updated, "Last updated 2026-09-27");
  for (const s of [
    "From Link</strong> downloads the JSFX script or impulse response",
    "the EffectDeck share extension downloads it the same way",
    "raw.githubusercontent.com",
    "api.github.com",
    "open chatgpt.com, or the ChatGPT app if it is installed",
    `href="${OPENAI_PRIVACY}"`,
    "makes a link on effectdeck.nemut.ai",
    "effetune.frieve.com, which nemut.ai does not run",
    "reads the link on the device and contacts no server",
    '<h2 id="report">Reporting a problem</h2>',
    `an email to ${EMAIL} or a new GitHub issue`,
    "it reaches GitHub when the page opens",
  ]) assert.ok(body.includes(s), s);
  // 頭の段落が指す節がどれも在る
  for (const id of ["presets", "links", "report", "website"]) {
    assert.ok(body.includes(`href="#${id}"`), `#${id}`);
    assert.ok(body.includes(`id="${id}"`), `id=${id}`);
  }
  assert.ok(!/[\u3040-\u30ff\u4e00-\u9fff]/.test(body), "Japanese in the policy");
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
  // アプリと同じ幅で読む（ETChainText.json(from:)）。base64url・= 無し・途中の改行と、
  // JSFX を名前で指す段（CHAIN.md）。
  const wideChain = [{ jsfx: "Tape Wobble" }, { nm: "Section", cm: "??>>~~" }, { nm: "Volume", en: false }];
  const wide = Buffer.from(JSON.stringify(wideChain)).toString("base64url");
  assert.ok(wide.includes("-") && wide.includes("_") && wide.length % 4 !== 0, wide);
  assert.deepEqual(chainEntries(`${wide.slice(0, 12)}\n${wide.slice(12)}`), [
    { section: false, name: "Tape Wobble", off: false },
    { section: true, name: "??>>~~ Section" },
    { section: false, name: "Volume", off: true },
  ]);
  // ロング形式
  const long = { pipeline: [{ name: "Section", parameters: { cm: "Main" } }, { name: "Volume", enabled: false }] };
  assert.deepEqual(chainEntries(Buffer.from(JSON.stringify(long)).toString("base64")), [
    { section: true, name: "Main Section" },
    { section: false, name: "Volume", off: true },
  ]);
  // アプリが置いた終端（"rr": true）は出さない。印の無い空の Section と、印があっても
  // 名前付き・切ってあるものは Section のまま（PipelineForm.parse と同じ条件）。
  const ends = [
    { nm: "Section", cm: "Main", en: true },
    { nm: "Volume", en: true },
    { nm: "Section", cm: "", en: true, rr: true },
    { nm: "Delay", en: true },
    { nm: "Section", cm: "", en: true },
    { nm: "Section", cm: "", en: false, rr: true },
    { nm: "Section", cm: "Named", en: true, rr: true },
  ];
  assert.deepEqual(chainEntries(Buffer.from(JSON.stringify(ends)).toString("base64")), [
    { section: true, name: "Main Section" },
    { section: false, name: "Volume", off: false },
    { section: false, name: "Delay", off: false },
    { section: true, name: "Section" },
    { section: true, name: "Section" },
    { section: true, name: "Named Section" },
  ]);
  const longEnd = { pipeline: [{ name: "Section", parameters: { cm: "A" } }, { name: "Volume" },
                               { name: "Section", enabled: true, parameters: { cm: "" }, rr: true },
                               { name: "Delay" }] };
  assert.deepEqual(chainEntries(Buffer.from(JSON.stringify(longEnd)).toString("base64")), [
    { section: true, name: "A Section" },
    { section: false, name: "Volume", off: false },
    { section: false, name: "Delay", off: false },
  ]);
});

console.log(`\n${n} passed`);
