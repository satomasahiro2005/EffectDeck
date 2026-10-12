// node site/test-worker.mjs（npm test から test.mjs の後に走る）
//
// src/worker.js を wrangler と同じ読み方（.svg は文字列・.png はバイト列、wrangler.toml の [[rules]]）で
// 束ね、Miniflare の dispatchFetch に URL ごと渡す。upstream を置かないので、
// fxd.nemut.ai と effectdeck.nemut.ai のどちらの名前で来たかがそのまま Worker に届く。
//
// 見ているのは振り分けの約束。
//   fxd は AASA のほかは全部 301
//   AASA は effectdeck と fxd が同じものを返す
//   バナーの app-argument と、/j のインライン script と CSP のハッシュの一致
//   開くボタンを置かない

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";
import { Miniflare } from "miniflare";
import { CHATGPT, CHATGPT_Q } from "./src/links.js";
import { GUIDE } from "./src/guide.js";
import { GUIDE_SHOTS } from "./src/shots.js";
import { existsSync } from "node:fs";

// 公式のページ（トップとプライバシーと /write 以外）。ガイドは 1 ページずつ。
const GUIDE_SLUGS = GUIDE.pages.map((g) => g.slug);
const PAGES = ["/guide", ...GUIDE_SLUGS.map((s) => `/guide/${s}`), "/about"];

const here = new URL(".", import.meta.url);
const vector = JSON.parse(readFileSync(new URL("test-vector.json", here), "utf8"));
const compatibilityDate = /^compatibility_date\s*=\s*"([^"]+)"/m.exec(
  readFileSync(new URL("wrangler.toml", here), "utf8"))[1];

const built = await esbuild.build({
  entryPoints: [fileURLToPath(new URL("src/worker.js", here))],
  bundle: true,
  format: "esm",
  write: false,
  logLevel: "silent",
  loader: { ".svg": "text", ".png": "binary", ".webp": "binary" },
});
// Miniflare 5 の形（wrangler 4.117 以降が使う）。1 本に束ねたので module も 1 つ。
const mf = new Miniflare({
  workers: [{
    config: {
      name: "effectdeck-site",
      compatibilityDate,
      manifest: { mainModule: "worker.js", modules: { "worker.js": { type: "esm", contents: built.outputFiles[0].text } } },
    },
  }],
});

const FXD = "fxd.nemut.ai";
const DECK = "effectdeck.nemut.ai";
const APP = "6812467517";

async function get(host, path, { method = "GET", lang = "en" } = {}) {
  const res = await mf.dispatchFetch(`https://${host}${path}`, {
    method,
    headers: { "accept-language": lang },
    redirect: "manual",
  });
  const bytes = new Uint8Array(await res.arrayBuffer());
  return { status: res.status, headers: res.headers, bytes, body: new TextDecoder().decode(bytes) };
}

let n = 0;
const test = async (name, fn) => { await fn(); n++; console.log("ok -", name); };
const sha = (s) => "sha256-" + createHash("sha256").update(s, "utf8").digest("base64");
const p = Buffer.from(JSON.stringify([{ nm: "Volume", en: true, vl: 0 }, { nm: "Parametric EQ", en: false }])).toString("base64");

try {
  await test("fxdb: every path 302s to the Discord invite, uncached", async () => {
    for (const path of ["/", "/anything", "/?x=1"]) {
      const r = await get("fxdb.nemut.ai", path);
      assert.equal(r.status, 302, path);
      assert.equal(r.headers.get("location"), "https://discord.gg/Y3DYJJmmDE", path);
      assert.equal(r.headers.get("cache-control"), "no-store", path);
    }
  });

  await test("fxdb: link-preview bots get the card, not the redirect", async () => {
    for (const ua of ["Twitterbot/1.0", "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)", "facebookexternalhit/1.1"]) {
      const res = await mf.dispatchFetch("https://fxdb.nemut.ai/", { headers: { "user-agent": ua }, redirect: "manual" });
      const body = await res.text();
      assert.equal(res.status, 200, ua);
      assert.match(body, /<meta property="og:title" content="EffectDeck Base">/, ua);
      assert.match(body, /og:image" content="https:\/\/effectdeck\.nemut\.ai\/og-discord\.png"/, ua);
      assert.match(body, /twitter:image" content="https:\/\/effectdeck\.nemut\.ai\/og-discord\.png\?v=2"/, ua);
      assert.match(body, /href="https:\/\/discord\.gg\/Y3DYJJmmDE"/, ua);
      assert.doesNotMatch(body, /http-equiv="refresh"/, ua);
    }
    for (const ua of ["Twitterbot/1.0", "Mozilla/5.0"]) {
      const res = await mf.dispatchFetch("https://fxdb.nemut.ai/robots.txt", { headers: { "user-agent": ua }, redirect: "manual" });
      assert.equal(res.status, 200, ua);
      assert.match(res.headers.get("content-type"), /^text\/plain/, ua);
      assert.equal(await res.text(), "User-agent: *\nAllow: /\n", ua);
    }
    const img = await get("effectdeck.nemut.ai", "/og-discord.png");
    assert.equal(img.status, 200);
    assert.equal(img.headers.get("content-type"), "image/png");
  });

  await test("fxd: everything but AASA 301s to effectdeck with the same path and query", async () => {
    for (const path of [
      "/",
      "/j",
      "/j/",
      `/?p=${p}`,
      `/?p=${encodeURIComponent(p)}&lang=ja`,
      "/privacy",
      "/write",
      ...PAGES,
      "/nope?x=1",
    ]) {
      const r = await get(FXD, path);
      assert.equal(r.status, 301, `${FXD}${path} -> ${r.status}`);
      assert.equal(r.headers.get("location"), `https://${DECK}${path}`);
      assert.equal(r.body, "");
    }
    const post = await get(FXD, "/j", { method: "POST" });
    assert.equal(post.status, 301);
    assert.equal(post.headers.get("location"), `https://${DECK}/j`);
  });

  // fxd も同じ AASA を返す（鎖のページの「アプリで開く」が fxd を指すため。worker.js の入口）。
  await test("effectdeck and fxd: AASA 200 application/json, the same document", async () => {
    for (const [host, path] of [DECK, FXD].flatMap((h) => ["/.well-known/apple-app-site-association", "/apple-app-site-association"].map((x) => [h, x]))) {
      const r = await get(host, path);
      assert.equal(r.status, 200, path);
      assert.equal(r.headers.get("content-type"), "application/json");
      const d = JSON.parse(r.body).applinks.details[0];
      assert.deepEqual(d.appIDs, ["C82ST8T9MN.ai.nemut.effetune"]);
      assert.deepEqual(d.components.map((c) => c["/"]), ["/", "/j", "/j/"]);
      assert.deepEqual(d.components[0]["?"], { p: "?*" });
      assert.deepEqual(d.paths, ["/j", "/j/"]);
    }
  });

  await test("home: banner has app-id only, no executable script, nothing points at fxd", async () => {
    const r = await get(DECK, "/");
    assert.equal(r.status, 200);
    assert.ok(r.body.includes(`<meta name="apple-itunes-app" content="app-id=${APP}">`));
    // JSON-LD はデータなので script-src 'none' のままでよい。ほかの script は置かない。
    const scripts = r.body.match(/<script[^>]*>/g) ?? [];
    assert.deepEqual(scripts, ['<script type="application/ld+json">']);
    assert.match(r.headers.get("content-security-policy"), /script-src 'none'/);
    assert.ok(!r.body.includes(FXD));
    assert.ok(r.body.includes("<title>EffectDeck — audio effects for any app on iPhone and iPad</title>"));
    assert.match(r.body, /<meta name="description" content="[^"]{50,}">/);
    for (const f of ["effects", "analyzers", "routing"]) assert.ok(r.body.includes(`src="/assets/shot-${f}.webp"`), f);
    assert.ok(r.body.includes('id="faq"'));
    assert.ok(r.body.includes("JamesDSP or ViPER4Android"));
    assert.ok(r.body.includes("not affiliated with, endorsed by, or supported by"));
  });

  await test("home: JSON-LD parses, and the FAQPage matches the FAQ on the page", async () => {
    const r = await get(DECK, "/");
    const m = /<script type="application\/ld\+json">([\s\S]*?)<\/script>/.exec(r.body);
    const ld = JSON.parse(m[1]);
    const app = ld["@graph"].find((x) => x["@type"] === "SoftwareApplication");
    assert.equal(app.operatingSystem, "iOS 27");
    assert.equal(app.offers.price, "0");
    const faq = ld["@graph"].find((x) => x["@type"] === "FAQPage");
    const faqBox = /<div class="faq">([\s\S]*?)<\/section>/.exec(r.body)[1];
    const onPage = [...faqBox.matchAll(/<div><h3>([^<]*)<\/h3>/g)].map((x) => x[1].replace(/&#39;/g, "'"));
    assert.ok(onPage.length >= 4);
    assert.deepEqual(faq.mainEntity.map((q) => q.name), onPage);
    for (const s of app.screenshot) {
      const u = new URL(s);
      assert.equal(u.host, DECK);
      assert.equal((await get(DECK, u.pathname)).status, 200, s);
    }
  });

  await test("Open Graph and Twitter card tags on every page, image from our origin", async () => {
    for (const path of ["/", ...PAGES, "/privacy", `/?p=${p}`, "/j", "/write"]) {
      const r = await get(DECK, path);
      const meta = (attr, key) => new RegExp(`<meta ${attr}="${key.replace(/[:.]/g, "\\$&")}" content="([^"]*)">`).exec(r.body)?.[1];
      // ガイドは自分の絵（public/og、tools/og-guide.mjs）。ほかは og.png
      const guide = /^\/guide(?:\/([a-z]+))?$/.exec(path);
      const og = guide ? `/og/guide${guide[1] ? "-" + guide[1] : ""}.png` : "/og.png";
      assert.equal(meta("property", "og:image"), `https://${DECK}${og}`, path);
      if (guide) assert.ok(existsSync(new URL(`public${og}`, here)), og);
      assert.equal(meta("property", "og:image:width"), "1200");
      assert.equal(meta("property", "og:image:height"), "630");
      assert.ok(meta("property", "og:title"), path);
      assert.ok(meta("property", "og:description"), path);
      assert.equal(meta("property", "og:type"), "website");
      assert.equal(meta("name", "twitter:card"), "summary_large_image");
      assert.equal(meta("name", "twitter:image"), `https://${DECK}${og}`, path);
      assert.ok(meta("name", "twitter:title"), path);
    }
    const home = (await get(DECK, "/")).body;
    assert.ok(home.includes(`<meta property="og:url" content="https://${DECK}/">`));
    assert.ok(home.includes(`<link rel="canonical" href="https://${DECK}/">`));
    const chain = (await get(DECK, `/?p=${p}`)).body;
    assert.ok(chain.includes('<meta property="og:description" content="An effect chain shared from EffectDeck: Volume, Parametric EQ">'));
    assert.ok(!chain.includes('property="og:url"'), "a share link is not canonical");
    // PC の EffeTune へ渡す口（内蔵だけの鎖なので中身はそのまま）
    assert.ok(chain.includes(`<a class="btn gh" href="https://effetune.frieve.com/effetune.html?p=${p.replace(/\+/g, "%2B")}">Open in EffeTune</a>`));
    const ext = Buffer.from(JSON.stringify([{ nm: "Volume" }, { nm: "Gain", external: "au:x" }])).toString("base64");
    assert.ok((await get(DECK, `/?p=${ext}`)).body.includes(">Open in EffeTune without 1 external effect</a>"));
    const og = await get(DECK, "/og.png");
    assert.equal(og.status, 200);
    assert.equal(og.headers.get("content-type"), "image/png");
    // PNG の IHDR から幅と高さ
    const dv = new DataView(og.bytes.buffer, og.bytes.byteOffset);
    assert.deepEqual([dv.getUint32(16), dv.getUint32(20)], [1200, 630]);
  });

  await test("English only: ?lang= and Accept-Language change nothing", async () => {
    const base = await get(DECK, "/");
    for (const [path, lang] of [["/", "ja"], ["/?lang=ja", "ja"], ["/?lang=en", "ja,en;q=0.1"]]) {
      const r = await get(DECK, path, { lang });
      assert.equal(r.status, 200);
      assert.equal(r.body, base.body, `${path} ${lang}`);
      assert.equal(r.headers.get("content-language"), null);
      assert.equal(r.headers.get("vary"), null);
    }
    for (const path of ["/", ...PAGES, "/privacy", "/j?lang=ja", "/write", `/?p=${p}&lang=ja`, "/nope"]) {
      const r = await get(DECK, path, { lang: "ja" });
      assert.ok(r.body.includes('<html lang="en">'), path);
      assert.ok(!/[぀-ヿ一-鿿]/.test(r.body), `Japanese in ${path}`);
      assert.ok(!r.body.includes("hreflang"), path);
      assert.ok(!r.body.includes("?lang="), path);
    }
    assert.equal((await get(DECK, "/assets/app-store-ja.svg")).status, 404);
  });

  await test("/llms.txt is plain text with the links", async () => {
    const r = await get(DECK, "/llms.txt");
    assert.equal(r.status, 200);
    assert.equal(r.headers.get("content-type"), "text/plain; charset=utf-8");
    assert.ok(r.body.startsWith("# EffectDeck\n"));
    for (const s of [`apps.apple.com/app/effectdeck/id${APP}`, "github.com/satomasahiro2005/EffectDeck", "#readme", "JSFX.md", "EffectDeck/releases"]) {
      assert.ok(r.body.includes(s), s);
    }
    assert.ok(!/testflight|\bbeta\b/i.test(r.body), "release status in llms.txt");
  });

  // リリースごとに変わることはページに書かない。TestFlight はフッターの名札 1 本だけ。
  await test("TestFlight only as one footer link on each page; hero is App Store + GitHub + FOSS", async () => {
    const footer = (body) => /<footer class="site">[\s\S]*<\/footer>/.exec(body)[0];
    for (const path of ["/", ...PAGES, "/privacy", "/j", "/write", `/?p=${p}`, "/nope"]) {
      const r = await get(DECK, path);
      const f = footer(r.body);
      const outside = r.body.replace(f, "");
      assert.ok(!/testflight|\bbeta\b/i.test(outside), `release status outside the footer on ${path}`);
      assert.equal(f.match(/testflight\.apple\.com/g)?.length, 1, path);
      assert.ok(f.includes('>Beta (TestFlight)</a>'), path);
      assert.ok(f.includes('href="https://github.com/satomasahiro2005/EffectDeck/releases">Release notes</a>'), path);
      assert.ok(f.includes("not affiliated with, endorsed by, or supported by"), path);
    }
    const home = (await get(DECK, "/")).body;
    const hero = /<section class="hero">[\s\S]*?<\/section>/.exec(home)[0];
    assert.ok(hero.includes(`apps.apple.com/app/effectdeck/id${APP}`), "App Store badge");
    assert.ok(hero.includes('<a class="btn gh" href="https://github.com/satomasahiro2005/EffectDeck">GitHub</a>'));
    assert.ok(hero.includes("Media Device Extension in iOS 27"));
    assert.ok(hero.includes("<h1>EffectDeck</h1>"));
    assert.match(hero, /<p class="foss">Free and open source \(<a href="[^"]+\/LICENSE">MIT<\/a>\)<\/p>/);
    // JSFX は全部の版に入ったので頭に書いてよい。版の話はしない。
    assert.ok(!/App Store version/.test(hero), "hero talks about builds");
    assert.match(home, /<meta name="description" content="[^"]*Free and open source \(MIT\)[^"]*">/);
    assert.match(home, /<meta property="og:description" content="[^"]*Free and open source \(MIT\)[^"]*">/);
    // FAQ の答えは本文の色（.faq p に color を付けない）
    assert.ok(!/\.faq p\{[^}]*color/.test(home), "FAQ answers are grey");
  });

  await test("chain: app-argument is the full effectdeck URL with the raw query, no Open button", async () => {
    for (const q of [`?p=${p}`, `?p=${encodeURIComponent(p)}&lang=ja`]) {
      const r = await get(DECK, "/" + q);
      assert.equal(r.status, 200, q);
      const arg = `https://${DECK}/${q}`.replace(/&/g, "&amp;");
      assert.ok(r.body.includes(`<meta name="apple-itunes-app" content="app-id=${APP}, app-argument=${arg}">`), q);
      assert.ok(!r.body.includes('class="btn"'), "Open button");
      assert.ok(!/Open in EffectDeck|EffectDeck で開く/.test(r.body));
      assert.ok(!r.body.includes(FXD));
      assert.ok(r.body.includes(`apps.apple.com/app/effectdeck/id${APP}`));
      assert.ok(r.body.includes("Parametric EQ"));
    }
  });

  await test("chain: unreadable p gets no app-argument", async () => {
    const r = await get(DECK, "/?p=%25%25%25garbage");
    assert.equal(r.status, 200);
    assert.ok(r.body.includes(`<meta name="apple-itunes-app" content="app-id=${APP}">`));
    assert.ok(!r.body.includes("app-argument"));
  });

  // /j の script を取り出して、後のテストでも使う。
  let script;
  await test("/j: one inline script right after the banner meta in head, CSP hash matches", async () => {
    const r = await get(DECK, "/j");
    assert.equal(r.status, 200);
    const m = new RegExp(`<meta name="apple-itunes-app" content="app-id=${APP}">\\n<script>([\\s\\S]*?)</script>`).exec(r.body);
    assert.ok(m, "script is not right after the banner meta");
    assert.ok(m.index < r.body.indexOf("</head>"), "script not in head");
    assert.equal(r.body.match(/<script/g).length, 1);
    script = m[1];
    assert.ok(r.headers.get("content-security-policy").includes(`script-src '${sha(script)}'`));
    assert.ok(script.includes(`"app-id=${APP}, app-argument=" + location.href`));
    assert.ok(!r.body.includes(FXD));
    assert.ok(!r.body.includes('class="btn" href'), "Open button");
    assert.ok(r.body.includes('id="copy"'));
    assert.ok(r.body.includes("Import JSFX → From Clipboard"));
    assert.ok(r.body.includes(`apps.apple.com/app/effectdeck/id${APP}`));
  });

  // ページの script を小さな DOM の代役で走らせる。
  const run = (href, readyState = "loading") => {
    const meta = { content: `app-id=${APP}`, setAttribute(k, v) { this[k] = v; } };
    const els = {};
    const listeners = [];
    const document = {
      readyState,
      title: "",
      querySelector: (s) => (s === 'meta[name="apple-itunes-app"]' ? meta : null),
      querySelectorAll: () => [],
      getElementById: (id) => (els[id] ??= { hidden: true, textContent: "", addEventListener() {} }),
      addEventListener: (ev, fn) => listeners.push([ev, fn]),
    };
    const location = { href, hash: new URL(href).hash };
    new Function("document", "location", "navigator", "getSelection", script)(document, location, {}, () => {});
    return { meta, els, listeners };
  };

  await test("/j script: app-argument is set before the DOM is ready, then the vector decodes", async () => {
    for (const href of [`https://${DECK}/j#${vector.payload}`, `https://${DECK}/j?lang=ja#${vector.payload}`]) {
      const { meta, els, listeners } = run(href);
      assert.equal(meta.content, `app-id=${APP}, app-argument=${href}`);
      assert.deepEqual(listeners.map(([ev]) => ev), ["DOMContentLoaded"]);
      await listeners[0][1]();
      assert.equal(els.src.textContent, vector.source);
      assert.equal(els.ok.hidden, false);
      assert.equal(els.title.textContent, "FXD Test Gain");
    }
  });

  await test("/j script: no payload means no app-argument and the unreadable block", async () => {
    const { meta, els } = run(`https://${DECK}/j`, "complete");
    await new Promise((r) => setTimeout(r, 50));
    assert.equal(meta.content, `app-id=${APP}`);
    assert.equal(els.bad.hidden, false);
  });

  // /write。依頼文は links.js の CHATGPT_Q そのもの（アプリと同じ字）。
  let writeJS;
  await test("/write: the request in a read-only box, Copy, Open ChatGPT, CSP hash, linked from the ChatGPT guide", async () => {
    const r = await get(DECK, "/write");
    assert.equal(r.status, 200);
    assert.ok(r.body.includes("<h1>Write a JSFX effect with ChatGPT</h1>"));
    const box = /<pre class="prompt" id="prompt">([^<]*)<\/pre>/.exec(r.body);
    assert.ok(box, "prompt box");
    assert.equal(box[1], CHATGPT_Q);
    assert.ok(!/contenteditable|<textarea/.test(r.body), "box is read-only");
    assert.ok(r.body.includes('<button class="btn quiet" id="copy" type="button">Copy</button>'));
    const open = /<a class="btn" href="([^"]+)">Open ChatGPT<\/a>/.exec(r.body);
    assert.ok(open, "Open ChatGPT");
    assert.equal(open[1], CHATGPT);
    assert.equal(new URL(open[1]).searchParams.get("q"), CHATGPT_Q);
    assert.match(r.body, /A paid ChatGPT plan is recommended/);
    assert.ok(r.body.includes("The same text works in other assistants."));
    assert.ok(r.body.includes("Import JSFX → From Files"));
    assert.ok(r.body.includes("From Clipboard"));
    assert.ok(r.body.includes(`<link rel="canonical" href="https://${DECK}/write">`));
    assert.ok(r.body.includes(`<meta name="apple-itunes-app" content="app-id=${APP}">`));
    const m = new RegExp(`<meta name="apple-itunes-app" content="app-id=${APP}">\\n<script>([\\s\\S]*?)</script>`).exec(r.body);
    assert.ok(m, "script");
    assert.equal(r.body.match(/<script/g).length, 1);
    writeJS = m[1];
    assert.ok(r.headers.get("content-security-policy").includes(`script-src '${sha(writeJS)}'`));
    assert.equal((await get(DECK, "/write/")).status, 200);
    const guide = (await get(DECK, "/guide/chatgpt")).body;
    assert.ok(guide.includes('<a href="/write">Write JSFX with ChatGPT</a>'));
    assert.ok((await get(DECK, "/llms.txt")).body.includes(`https://${DECK}/write`));
  });

  await test("/write script: Copy writes the box's text, and selects it when the clipboard refuses", async () => {
    for (const refuse of [false, true]) {
      const els = {};
      let written = null;
      let selected = null;
      const document = {
        readyState: "complete",
        getElementById: (id) => (els[id] ??= {
          textContent: id === "prompt" ? CHATGPT_Q : "Copy",
          addEventListener(ev, fn) { this[ev] = fn; },
        }),
        createRange: () => ({ selectNodeContents(n) { this.n = n; } }),
      };
      const navigator = { clipboard: { writeText: async (s) => { if (refuse) throw new Error("no"); written = s; } } };
      const getSelection = () => ({ removeAllRanges() {}, addRange(r) { selected = r.n; } });
      new Function("document", "navigator", "getSelection", writeJS)(document, navigator, getSelection);
      await els.copy.click();
      if (refuse) {
        assert.equal(selected, els.prompt);
        assert.equal(els.copy.textContent, "Copy");
      } else {
        assert.equal(written, CHATGPT_Q);
        assert.equal(els.copy.textContent, "Copied");
      }
    }
  });

  await test("other effectdeck paths", async () => {
    for (const [path, status] of [
      ["/privacy", 200], ["/privacy/", 200], ["/assets/app-store-en.svg", 200], ["/nope", 404],
      ["/assets/shot-nope.webp", 404], ["/assets/shot-constructor.webp", 404], ["/assets/shot-effects.png", 404],
    ]) {
      assert.equal((await get(DECK, path)).status, status, path);
    }
    for (const f of ["effects", "analyzers", "routing"]) {
      const r = await get(DECK, `/assets/shot-${f}.webp`);
      assert.equal(r.headers.get("content-type"), "image/webp");
      assert.deepEqual(r.bytes, new Uint8Array(readFileSync(new URL(`assets/shot-${f}.webp`, here))));
      assert.ok(r.bytes.length < 60_000, `${f} ${r.bytes.length} bytes`);
    }
    const moved = await get(DECK, "/privacy.html?lang=ja");
    assert.equal(moved.status, 301);
    assert.equal(moved.headers.get("location"), "/privacy?lang=ja");
    const icon = await get(DECK, "/icon.png");
    assert.equal(icon.headers.get("content-type"), "image/png");
    assert.deepEqual(icon.bytes, new Uint8Array(readFileSync(new URL("../docs/icon.png", here))));
    const privacy = (await get(DECK, "/privacy")).body.replace(/\s+/g, " ");
    for (const s of ["makes a link on effectdeck.nemut.ai", "api.github.com", "open chatgpt.com", "Reporting a problem"]) {
      assert.ok(privacy.includes(s), s);
    }
    assert.equal((await get(DECK, "/", { method: "POST" })).status, 405);
  });

  // トップは主張（Why DSP?）→ ガイドの入口 → 出自（短く）→ Support → FAQ。ガイドは 1 ページずつ。
  await test("home: the guide first (a button under the headline and a card per page), then Why DSP, then provenance", async () => {
    const home = (await get(DECK, "/")).body;
    const order = ['id="start"', 'id="why"', 'id="about"', 'id="support"', 'id="faq"'].map((s) => home.indexOf(s));
    assert.ok(order.every((i) => i > 0), JSON.stringify(order));
    assert.deepEqual([...order].sort((a, b) => a - b), order, "section order");
    // トップで持たなくなった節（中身はガイドへ移した）
    for (const id of ["how", "jsfx", "share", "examples"]) assert.ok(!home.includes(`<section id="${id}">`), id);
    const start = /<section id="start">[\s\S]*?<\/section>/.exec(home)[0];
    assert.deepEqual([...start.matchAll(/href="\/guide\/([a-z]+)"/g)].map((m) => m[1]), GUIDE_SLUGS);
    assert.equal(start.match(/class="(ph thumb|shot-thumb)"/g)?.length, GUIDE_SLUGS.length, "a picture on every card");
    const about = /<section id="about">[\s\S]*?<\/section>/.exec(home)[0];
    assert.ok(about.includes("not affiliated with, endorsed by, or supported by"));
    assert.ok(about.includes("https://www.sony.com/ja/SonyInfo/technology/stories/entries/2021_kobayashi/"));
    assert.ok(about.includes('href="/about"'));
    assert.ok(!/endorsed by Sony|Sony-approved|supervised by/i.test(home));
    assert.ok(home.includes('<a href="/guide">Guide</a>'), "nav");
    const hero = /<section class="hero">[\s\S]*?<\/section>/.exec(home)[0];
    assert.ok(hero.includes('href="/guide"'), "the guide is one tap from the headline");
    assert.ok(!home.includes("What the measurements say"), "no claims about blind comparison");
  });

  await test("/guide is the contents; /guide/<part> are pages with prev/next and only the lightbox script", async () => {
    const index = await get(DECK, "/guide");
    assert.equal(index.status, 200);
    assert.deepEqual([...index.body.matchAll(/href="\/guide\/([a-z]+)"/g)].map((m) => m[1]), GUIDE_SLUGS);
    assert.ok(index.body.includes(`<link rel="canonical" href="https://${DECK}/guide">`));
    const titles = new Set();
    const ids = [];
    for (const [i, slug] of GUIDE_SLUGS.entries()) {
      const r = await get(DECK, `/guide/${slug}`);
      assert.equal(r.status, 200, slug);
      assert.equal((await get(DECK, `/guide/${slug}/`)).status, 200, `${slug}/`);
      // 外から読む script は無い。インラインの lightbox 1 本だけで、CSP はそのハッシュだけ許す
      const scripts = [...r.body.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
      assert.equal(scripts.length, 1, slug);
      assert.ok(!/<script[^>]+src=/.test(r.body), slug);
      assert.ok(r.headers.get("content-security-policy").includes(`script-src '${sha(scripts[0])}'`), slug);
      assert.ok(r.body.includes('<dialog id="lightbox"'), slug);
      assert.ok(r.body.includes(`<link rel="canonical" href="https://${DECK}/guide/${slug}">`), slug);
      const title = /<title>([^<]+)<\/title>/.exec(r.body)[1];
      titles.add(title);
      assert.equal(r.body.match(/<h1>/g).length, 1, slug);
      assert.ok(r.body.includes('<p class="crumbs"><a href="/guide">Guide</a>'), slug);
      // 前へ／次へは並びのとおり
      const prev = /rel="prev" href="\/guide\/([a-z]+)"/.exec(r.body)?.[1];
      const next = /rel="next" href="\/guide\/([a-z]+)"/.exec(r.body)?.[1];
      assert.equal(prev, GUIDE_SLUGS[i - 1], `${slug} prev`);
      assert.equal(next, GUIDE_SLUGS[i + 1], `${slug} next`);
      assert.ok(['class="ph ', "/assets/shot-", 'src="/shots/'].some((x) => r.body.includes(x)), `${slug} has pictures`);
      assert.ok(r.body.includes('class="done"'), slug);
      ids.push(...[...r.body.matchAll(/<span class="ph-id">([^<]+)<\/span>/g)].map((m) => m[1]));
      // 撮ってある枠は本物（静的アセット /shots/<id>.webp）。
      ids.push(...[...r.body.matchAll(/src="\/shots\/([a-z0-9-]+)\.webp"/g)].map((m) => m[1]));
      for (const [, img] of r.body.matchAll(/src="(\/assets\/shot-[a-z]+\.webp)"/g)) {
        assert.equal((await get(DECK, img)).status, 200, img);
      }
    }
    assert.equal(titles.size, GUIDE_SLUGS.length, "every page has its own title");
    // 枠（撮ったものと撮るまでのもの）。名前（＝撮ったときのファイル名）はガイド全体で重ならない
    assert.ok(ids.length >= 45, `${ids.length} pictures`);
    assert.equal(new Set(ids).size, ids.length, "placeholder ids repeat");
    assert.equal((await get(DECK, "/guide/nope")).status, 404);
    assert.equal((await get(DECK, "/guide/connect/x")).status, 404);
  });

  await test("guide pages use the app's own labels; BRIR is one downloaded True Stereo file with Dry and Direct Cut off", async () => {
    const all = (await Promise.all(GUIDE_SLUGS.map((s) => get(DECK, `/guide/${s}`)))).map((r) => r.body).join("\n");
    for (const label of ["Output Correction", "Save current chain", "Share this chain", "Import from clipboard", "System Presets",
      "15Band PEQ", "IR Reverb", "Direct Cut", "Wet Level", "BRIR_R01_C1_True_Stereo.wav"]) {
      assert.ok(all.includes(label), label);
    }
    const brir = (await get(DECK, "/guide/brir")).body;
    assert.match(brir, /Turn <strong>Dry<\/strong> off/);
    assert.match(brir, /<strong>Direct Cut<\/strong> off/);
    assert.match(brir, /CC BY-NC-SA 4\.0/);
    assert.ok(brir.includes("https://github.com/ShanonPearce/ASH-Listening-Set/tree/main/BRIRs"));
    // Unable to Connect（Spotify の Canvas）は Spotify 側で直ったので書かない
    assert.ok(!/Unable to Connect|Canvas/.test(all), "Unable to Connect is gone");
    assert.ok(!/Chapter \d/.test(all), "no chapter numbers left in the text");
    const chatgpt = (await get(DECK, "/guide/chatgpt")).body;
    assert.match(chatgpt, /paid plan is recommended/);
    assert.ok(chatgpt.includes('<a href="/write">Write JSFX with ChatGPT</a>'));
    assert.ok(!all.includes("aes.org"), "AES links are names only (not verified)");
  });

  // src/shots.js（tools/guide-shots.mjs が書く）に載っている画像は public/shots に在る。載っている枠は本物を出す。
  await test("guide shots: every listed image exists, and listed ids render as images", async () => {
    for (const id of GUIDE_SHOTS) {
      assert.ok(existsSync(new URL(`public/shots/${id}.webp`, here)), id);
      // 押して開く大きい版（カードの絵は押させないので無い）
      if (!id.startsWith("card-")) assert.ok(existsSync(new URL(`public/shots/full/${id}.webp`, here)), `full/${id}`);
    }
    const all = (await Promise.all(GUIDE_SLUGS.map((s) => get(DECK, `/guide/${s}`)))).map((r) => r.body).join(" ")
      + (await get(DECK, "/")).body;
    for (const id of GUIDE_SHOTS) {
      if (!all.includes(id)) continue;
      assert.ok(all.includes(`src="/shots/${id}.webp"`), `${id} should be an image`);
      if (!id.startsWith("card-")) assert.ok(all.includes(`<a class="zoom" href="/shots/full/${id}.webp"`), `${id} opens large`);
      assert.ok(!all.includes(`<span class="ph-id">${id}</span>`), `${id} is still a placeholder`);
    }
  });

  await test("/about: EffeTune provenance, the port, and the sources", async () => {
    const r = await get(DECK, "/about");
    assert.equal(r.status, 200);
    assert.equal((await get(DECK, "/about/")).status, 200);
    for (const id of ["effetune", "port", "sources"]) assert.ok(r.body.includes(`id="${id}"`), id);
    assert.ok(r.body.includes("not affiliated with, endorsed by, or supported by"));
    assert.ok(r.body.includes("Distinguished Engineer"));
    assert.ok(r.body.includes("ir_prepare_golden.mjs"));
    assert.ok(!r.body.includes("aes.org"));
    assert.ok(r.body.includes(`<link rel="canonical" href="https://${DECK}/about">`));
  });

  await test("robots.txt and sitemap list only the official pages; share pages are noindex", async () => {
    const robots = await get(DECK, "/robots.txt");
    assert.equal(robots.status, 200);
    assert.match(robots.body, /^User-agent: \*\nAllow: \/\nSitemap: https:\/\/effectdeck\.nemut\.ai\/sitemap\.xml\n$/);
    const map = await get(DECK, "/sitemap.xml");
    assert.equal(map.status, 200);
    assert.match(map.headers.get("content-type"), /^application\/xml/);
    assert.deepEqual([...map.body.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]),
      ["/", ...PAGES, "/write", "/privacy"].map((x) => `https://effectdeck.nemut.ai${x}`));
    for (const path of [`/?p=${p}`, "/j"]) {
      const res = await get(DECK, path);
      assert.equal(res.headers.get("x-robots-tag"), "noindex, follow", path);
      assert.ok(res.body.includes('<meta name="robots" content="noindex, follow">'), path);
    }
    for (const path of ["/", ...PAGES, "/write", "/privacy"]) {
      const res = await get(DECK, path);
      assert.equal(res.headers.get("x-robots-tag"), null, path);
      assert.ok(!res.body.includes('name="robots"'), path);
    }
  });
} finally {
  await mf.dispose();
}

console.log(`\n${n} passed`);
