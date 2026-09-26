// node site/test-worker.mjs（npm test から test.mjs の後に走る）
//
// src/worker.js を wrangler と同じ読み方（.svg は文字列・.png はバイト列、wrangler.toml の [[rules]]）で
// 束ね、Miniflare の dispatchFetch に URL ごと渡す。upstream を置かないので、
// fxd.nemut.ai と effectdeck.nemut.ai のどちらの名前で来たかがそのまま Worker に届く。
//
// 見ているのは振り分けの約束。
//   fxd は AASA も含めて全部 301（AASA の分岐を fxd の上へ戻すとここで落ちる）
//   AASA を返すのは effectdeck だけ
//   バナーの app-argument と、/j のインライン script と CSP のハッシュの一致
//   開くボタンを置かない

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";
import { Miniflare } from "miniflare";
import { CHATGPT, CHATGPT_Q } from "./src/links.js";

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
  await test("fxd: everything 301s to effectdeck with the same path and query, AASA included", async () => {
    for (const path of [
      "/.well-known/apple-app-site-association",
      "/apple-app-site-association",
      "/",
      "/j",
      "/j/",
      `/?p=${p}`,
      `/?p=${encodeURIComponent(p)}&lang=ja`,
      "/privacy",
      "/write",
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

  await test("effectdeck: AASA 200 application/json, the only host that serves it", async () => {
    for (const path of ["/.well-known/apple-app-site-association", "/apple-app-site-association"]) {
      const r = await get(DECK, path);
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
    assert.ok(r.body.includes("<title>EffectDeck — audio effects for any app on iPhone</title>"));
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
    const onPage = [...r.body.matchAll(/<div><h3>([^<]*)<\/h3>/g)].map((x) => x[1].replace(/&#39;/g, "'"));
    assert.ok(onPage.length >= 4);
    assert.deepEqual(faq.mainEntity.map((q) => q.name), onPage);
    for (const s of app.screenshot) {
      const u = new URL(s);
      assert.equal(u.host, DECK);
      assert.equal((await get(DECK, u.pathname)).status, 200, s);
    }
  });

  await test("Open Graph and Twitter card tags on every page, image from our origin", async () => {
    for (const path of ["/", "/privacy", `/?p=${p}`, "/j", "/write"]) {
      const r = await get(DECK, path);
      const meta = (attr, key) => new RegExp(`<meta ${attr}="${key.replace(/[:.]/g, "\\$&")}" content="([^"]*)">`).exec(r.body)?.[1];
      assert.equal(meta("property", "og:image"), `https://${DECK}/og.png`, path);
      assert.equal(meta("property", "og:image:width"), "1200");
      assert.equal(meta("property", "og:image:height"), "630");
      assert.ok(meta("property", "og:title"), path);
      assert.ok(meta("property", "og:description"), path);
      assert.equal(meta("property", "og:type"), "website");
      assert.equal(meta("name", "twitter:card"), "summary_large_image");
      assert.equal(meta("name", "twitter:image"), `https://${DECK}/og.png`);
      assert.ok(meta("name", "twitter:title"), path);
    }
    const home = (await get(DECK, "/")).body;
    assert.ok(home.includes(`<meta property="og:url" content="https://${DECK}/">`));
    assert.ok(home.includes(`<link rel="canonical" href="https://${DECK}/">`));
    const chain = (await get(DECK, `/?p=${p}`)).body;
    assert.ok(chain.includes('<meta property="og:description" content="An effect chain shared from EffectDeck: Volume, Parametric EQ">'));
    assert.ok(!chain.includes('property="og:url"'), "a share link is not canonical");
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
    for (const path of ["/", "/privacy", "/j?lang=ja", "/write", `/?p=${p}&lang=ja`, "/nope"]) {
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
    for (const path of ["/", "/privacy", "/j", "/write", `/?p=${p}`, "/nope"]) {
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
    assert.match(hero, /<p class="foss">Free and open source \(<a href="[^"]+\/LICENSE">MIT<\/a>\)<\/p>/);
    assert.ok(!/JSFX|App Store version/.test(hero), "hero talks about builds");
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
  await test("/write: the request in a read-only box, Copy, Open ChatGPT, CSP hash, linked from home", async () => {
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
    assert.ok(r.body.includes("Import JSFX → From Clipboard"));
    assert.ok(r.body.includes(`<link rel="canonical" href="https://${DECK}/write">`));
    assert.ok(r.body.includes(`<meta name="apple-itunes-app" content="app-id=${APP}">`));
    const m = new RegExp(`<meta name="apple-itunes-app" content="app-id=${APP}">\\n<script>([\\s\\S]*?)</script>`).exec(r.body);
    assert.ok(m, "script");
    assert.equal(r.body.match(/<script/g).length, 1);
    writeJS = m[1];
    assert.ok(r.headers.get("content-security-policy").includes(`script-src '${sha(writeJS)}'`));
    assert.equal((await get(DECK, "/write/")).status, 200);
    const home = (await get(DECK, "/")).body;
    const jsfx = /<section id="jsfx">[\s\S]*?<\/section>/.exec(home)[0];
    assert.ok(jsfx.includes('<a href="/write">Write with ChatGPT</a>'));
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
    assert.ok((await get(DECK, "/privacy")).body.includes("makes a link on effectdeck.nemut.ai"));
    assert.equal((await get(DECK, "/", { method: "POST" })).status, 405);
  });
} finally {
  await mf.dispose();
}

console.log(`\n${n} passed`);
