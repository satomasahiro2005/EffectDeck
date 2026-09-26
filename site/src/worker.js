// effectdeck.nemut.ai と fxd.nemut.ai を 1 本の Worker で受ける。
//
//   effectdeck.nemut.ai  アプリが作る共有リンクの宛先で、唯一の associated domain。
//                        AASA とページを返す。アプリが入っていればリンクはアプリで開き、
//                        入っていなければ同じ URL のページに着く。
//   fxd.nemut.ai         人がプロフィールや投稿に打つための短い別名。**ページも AASA も持たない。**
//                        AASA を含めて全部を effectdeck の同じパスとクエリへ 301 する。
//
// **ページからアプリへ渡すボタンは置かない。**Universal Link は別のドメインへ飛ぶときにしか
// 立たず、effectdeck のページから effectdeck を指しても Safari の中でページが開くだけ。
// 代わりに Smart App Banner（apple-itunes-app）の app-argument に今の URL を入れる。
// /j の中身は # の後ろにあり、サーバーには届かない。app-argument に入れるのも、
// ソースを戻すのもページの中の JS。
//
// ページは英語だけ（2026-09-26 に日本語をやめた）。古いリンクの ?lang= は読まずに捨てる。

import { decodeFXD } from "./fxd.js";
import { chainEntries } from "./parse.js";
import { TEXT, FAQ, PRIVACY, LLMS_TXT } from "./text.js";
import { ORIGIN, homeLd } from "./seo.js";
import {
  DECK_HOST, LINK_HOST, APP_ID, APP_STORE, APP_STORE_ID, GITHUB, RELEASES, TESTFLIGHT, TWITTER,
  CHATGPT, CHATGPT_Q,
} from "./links.js";
import badgeEn from "../assets/app-store-en.svg";
import ogImage from "../assets/og.png";
import shotEffects from "../assets/shot-effects.webp";
import shotAnalyzers from "../assets/shot-analyzers.webp";
import shotRouting from "../assets/shot-routing.webp";
import iconLight from "../../docs/icon.png";
import iconDark from "../../docs/icon-dark.png";

// MARK: - AASA

const AASA = JSON.stringify({
  applinks: {
    details: [
      {
        appIDs: [APP_ID],
        components: [
          // **p が無い "/" は公式ページなので拾わない。**
          { "/": "/", "?": { p: "?*" }, comment: "effect chain" },
          // アプリ（ETFXDLink.route）は /j/ も受けるので揃える。
          { "/": "/j", comment: "JSFX script; payload is in the fragment" },
          { "/": "/j/", comment: "JSFX script; payload is in the fragment" },
        ],
        // iOS 12 以前の書き方。アプリは iOS 27 からなので読まれない。
        // **"/" は入れない。**旧形式はクエリを見ないので、入れると公式ページまで拾う。
        appID: APP_ID,
        paths: ["/j", "/j/"],
      },
    ],
  },
});

function aasa() {
  return new Response(AASA, {
    headers: {
      "content-type": "application/json",
      "cache-control": "public, max-age=3600",
    },
  });
}

const AASA_PATHS = new Set(["/.well-known/apple-app-site-association", "/apple-app-site-association"]);

// MARK: - 入口

export default {
  async fetch(request) {
    const url = new URL(request.url);

    // **fxd は 301 だけ。AASA も転送する。**パスとクエリをそのまま付け替える（# はブラウザが引き継ぐ）。
    // Apple は転送された AASA を読まないので、fxd は associated domain にならない。それでよい。
    if (url.hostname === LINK_HOST) {
      return new Response(null, {
        status: 301,
        headers: {
          location: `https://${DECK_HOST}${url.pathname}${url.search}`,
          "cache-control": "public, max-age=86400",
        },
      });
    }

    if (AASA_PATHS.has(url.pathname)) return aasa();

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", { status: 405, headers: { allow: "GET, HEAD" } });
    }
    return deck(url);
  },
};

// MARK: - effectdeck.nemut.ai

// 画像は名前で引く。/assets/shot-<file>.webp の file は TEXT.shots と揃える。
const SHOT_BYTES = { effects: shotEffects, analyzers: shotAnalyzers, routing: shotRouting };

async function deck(url) {
  const path = url.pathname;
  switch (path) {
    case "/":
      return url.searchParams.get("p") ? chainPage(url) : homePage();
    case "/j":
    case "/j/":
      return jsfxPage();
    case "/write":
    case "/write/":
      return writePage();
    case "/privacy":
    case "/privacy/":
      return privacyPage();
    case "/privacy.html":
      return redirect(url, "/privacy");
    case "/llms.txt":
      return new Response(LLMS_TXT, {
        headers: {
          "content-type": "text/plain; charset=utf-8",
          "cache-control": "public, max-age=3600",
          "x-content-type-options": "nosniff",
        },
      });
    case "/assets/app-store-en.svg":
      return asset(badgeEn, "image/svg+xml");
    case "/og.png":
      return asset(ogImage, "image/png");
    case "/icon.png":
    case "/favicon.ico":
    case "/apple-touch-icon.png":
      return asset(iconLight, "image/png");
    case "/icon-dark.png":
      return asset(iconDark, "image/png");
  }
  const shot = /^\/assets\/shot-([a-z]+)\.webp$/.exec(path);
  if (shot && Object.hasOwn(SHOT_BYTES, shot[1])) return asset(SHOT_BYTES[shot[1]], "image/webp");
  return notFound();
}

function redirect(url, path) {
  return new Response(null, { status: 301, headers: { location: path + url.search } });
}

function asset(body, type) {
  return new Response(body, {
    headers: {
      "content-type": type,
      "cache-control": "public, max-age=86400",
      "x-content-type-options": "nosniff",
    },
  });
}

// MARK: - 組み立て

const esc = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

// 色と字は qr.nemut.ai（同じ作者の別アプリのページ）に寄せる。
// **Web フォントは読まない。**CSP（font-src 無し）とプライバシーポリシー（Cloudflare 以外に届かない）を
// 崩さないため。Inter と JetBrains Mono の代わりにシステムの字を使う。
const CSS = `
:root{color-scheme:light dark;--bg:#fafafa;--fg:#1f1f1f;--muted:#656d76;--rule:#d1d9e0;--accent:#0969da;--on-accent:#fff;--surface:#f6f8fa;--shadow:0 18px 44px rgba(31,35,40,.14);--page:41rem;--mono:ui-monospace,SFMono-Regular,"SF Mono","Cascadia Mono",Menlo,Consolas,monospace}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#9198a1;--rule:#30363d;--accent:#4493f8;--on-accent:#0d1117;--surface:#151b23;--shadow:0 18px 44px rgba(0,0,0,.5)}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.7 -apple-system,BlinkMacSystemFont,"Segoe UI","Helvetica Neue",Arial,sans-serif;-webkit-font-smoothing:antialiased}
body.wide{--page:1160px}
body.code{--page:60rem}
.wrap{max-width:var(--page);margin:0 auto;padding-inline:16px}
@media (min-width:720px){.wrap{padding-inline:24px}}
header.site{border-bottom:1px solid var(--rule)}
header.site .wrap,footer.site .wrap{max-width:1160px}
header.site .wrap{display:flex;align-items:center;justify-content:space-between;gap:12px;padding-block:4px}
.brand{display:flex;align-items:center;gap:10px;color:inherit;text-decoration:none;font:600 1rem/1 var(--mono)}
.brand img{display:block;width:28px;height:28px;border-radius:7px}
nav.site{display:flex;flex-wrap:wrap;gap:4px 18px;font-size:.9rem}
nav.site a{color:var(--muted);text-decoration:none;padding-block:10px}
nav.site a:hover{color:var(--accent)}
main{padding-block:32px 8px}
h1,h2{font-family:var(--mono);font-weight:600;letter-spacing:-.01em}
h1{font-size:1.7rem;line-height:1.25;margin:0 0 8px;text-wrap:balance;overflow-wrap:anywhere}
h2{font-size:1.3rem;line-height:1.4;margin:40px 0 10px;padding-top:24px;border-top:1px solid var(--rule)}
h3{font-size:1.05rem;line-height:1.45;margin:0 0 6px}
p{margin:0 0 12px}
p,ul{max-width:70ch}
ul{margin:0 0 12px;padding-left:1.2em}
li{margin-bottom:6px}
a{color:var(--accent)}
code{font:.9em var(--mono)}
.muted{color:var(--muted)}
.lead{color:var(--muted);margin-bottom:24px}
.actions{display:flex;flex-wrap:wrap;align-items:center;gap:12px;margin:20px 0}
.badge{display:inline-block}
.badge img{display:block;height:48px;width:auto}
.btn{display:inline-block;background:var(--accent);color:var(--on-accent);text-decoration:none;padding:11px 18px;border-radius:8px;border:0;font:inherit;font-weight:600;cursor:pointer}
.btn.quiet{background:transparent;color:var(--accent);border:1px solid var(--rule);padding:6px 12px;font-size:.9rem}
.links{display:flex;flex-wrap:wrap;gap:8px 20px}
.hero{text-align:center;padding:24px 0 8px}
.hero-icon{display:block;width:112px;height:112px;border-radius:25px;margin:0 auto 18px}
@media (prefers-color-scheme:light){.hero-icon{box-shadow:0 0 0 1px var(--rule),0 6px 20px rgba(31,35,40,.10)}}
.hero h1{font-size:2.1rem;margin-bottom:10px}
.hero .lead{font-size:1.15rem;max-width:34rem;margin:0 auto}
.hero .lead{text-wrap:balance}
.hero .actions{justify-content:center;margin:24px 0 12px}
.btn.gh{display:inline-flex;align-items:center;height:48px;padding:0 20px;background:transparent;color:var(--fg);border:1px solid var(--rule);border-radius:10px}
.btn.gh:hover{border-color:var(--accent);color:var(--accent)}
.hero .foss{font-size:.92rem;color:var(--muted);margin:0 auto}
.hero .foss a{color:inherit}
.shots{list-style:none;display:flex;gap:16px;overflow-x:auto;scroll-snap-type:x mandatory;margin:24px -16px 8px;padding:8px 16px 32px;scrollbar-width:none;max-width:none}
.shots::-webkit-scrollbar{display:none}
.shots li{flex:0 0 min(64vw,260px);scroll-snap-align:center;margin:0}
.shots figure{margin:0}
.shots img{display:block;width:100%;height:auto;border-radius:22px;border:1px solid var(--rule);box-shadow:var(--shadow);background:#f2f2f7}
@media (prefers-color-scheme:dark){.shots img{filter:brightness(.88)}}
.shots figcaption{margin-top:14px;text-align:center;font:500 .88rem var(--mono);color:var(--muted)}
.cols{display:grid;grid-template-columns:minmax(0,1fr);column-gap:64px}
.cols>section{min-width:0}
.faq{margin-top:16px}
.faq>div{break-inside:avoid;margin-bottom:24px}
.faq p{margin:0}
@media (min-width:720px){
  main{padding-block:24px 8px}
  .hero{padding:24px 0 8px}
  .hero h1{font-size:2.6rem}
  .shots{display:grid;grid-template-columns:repeat(3,minmax(0,280px));justify-content:center;gap:48px;overflow:visible;margin:32px 0 16px;padding:0 0 24px}
}
@media (min-width:960px){
  .cols{grid-template-columns:repeat(2,minmax(0,1fr))}
  .faq{columns:2 420px;column-gap:64px}
  .faq>div{margin-bottom:28px}
}
@media (min-width:1100px){
  .shots{grid-template-columns:repeat(3,minmax(0,1fr));gap:64px}
}
.chain{list-style:none;padding:0;border-top:1px solid var(--rule)}
.chain li{margin:0;padding:8px 0;border-bottom:1px solid var(--rule);overflow-wrap:anywhere}
.chain li.section{font-size:.85rem;color:var(--muted);padding-top:16px}
.chain li.off{color:var(--muted)}
.chain .tag{font-size:.78rem;border:1px solid var(--rule);border-radius:4px;padding:0 5px;margin-left:8px}
pre{background:var(--surface);border:1px solid var(--rule);border-radius:8px;padding:12px;margin:0 0 12px;overflow:auto;max-height:60vh;font:13px/1.5 var(--mono);white-space:pre;tab-size:4}
.src-head{display:flex;justify-content:flex-end;margin:24px 0 0;padding:6px 8px;background:var(--surface);border:1px solid var(--rule);border-bottom:0;border-radius:8px 8px 0 0}
.src-head+pre{border-radius:0 0 8px 8px}
pre.prompt{white-space:pre-wrap;overflow-wrap:anywhere;max-height:none;font-size:14px;line-height:1.6}
footer.site{margin-top:56px;border-top:1px solid var(--rule);color:var(--muted);font-size:.88rem}
footer.site .wrap{padding-block:28px 40px}
footer.site a{color:inherit}
footer.site .sep{margin:0 6px}
[hidden]{display:none!important}
`;

// インラインの script は CSP のハッシュで許す。中身ごとに一度だけ計算する。
const hashes = new Map();
async function scriptHash(js) {
  if (!hashes.has(js)) {
    const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(js));
    hashes.set(js, "sha256-" + btoa(String.fromCharCode(...new Uint8Array(d))));
  }
  return hashes.get(js);
}

// **script は head の apple-itunes-app の直後に置く。**/j はこの script が app-argument を
// 書き足すので、Safari がバナーを読む前に走らせたい。DOM に触る部分は script 側で待つ。
const bannerPrefix = `app-id=${APP_STORE_ID}, app-argument=`;

const OG_IMAGE = `${ORIGIN}/og.png`;
const OG_ALT = "EffectDeck icon and two screenshots of the app";

// JSON-LD は実行されない（type が JS でない）ので CSP の script-src には掛からない。
// **< は \u003c に直す。**中身に </script> が混ざっても閉じないように。
const ldScript = (data) =>
  `<script type="application/ld+json">${JSON.stringify(data).replace(/</g, "\\u003c")}</script>`;

async function page({
  title, body, status = 200, script = null, banner = null,
  description = TEXT.description, canonical = null, width = "", ld = null,
}) {
  const t = TEXT;
  const bannerContent = banner ? bannerPrefix + banner : `app-id=${APP_STORE_ID}`;
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<meta name="apple-itunes-app" content="${esc(bannerContent)}">
${script ? `<script>${script}</script>` : ""}
<meta name="referrer" content="no-referrer">
${canonical ? `<link rel="canonical" href="${esc(canonical)}">\n` : ""}<meta property="og:type" content="website">
<meta property="og:site_name" content="EffectDeck">
<meta property="og:locale" content="en_US">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
${canonical ? `<meta property="og:url" content="${esc(canonical)}">\n` : ""}<meta property="og:image" content="${OG_IMAGE}">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="${OG_ALT}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:site" content="@${TWITTER.split("/").pop()}">
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(description)}">
<meta name="twitter:image" content="${OG_IMAGE}">
<meta name="twitter:image:alt" content="${OG_ALT}">
<meta name="theme-color" content="#fafafa" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0d1117" media="(prefers-color-scheme: dark)">
<link rel="icon" type="image/png" href="/icon.png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
${ld ? ldScript(ld) + "\n" : ""}<style>${CSS}</style>
</head>
<body${width ? ` class="${width}"` : ""}>
<header class="site"><div class="wrap">
<a class="brand" href="/"><picture><source srcset="/icon-dark.png" media="(prefers-color-scheme: dark)"><img src="/icon.png" alt=""></picture>EffectDeck</a>
<nav class="site"><a href="/#faq">FAQ</a><a href="/#jsfx">JSFX</a><a href="${GITHUB}">GitHub</a></nav>
</div></header>
<main class="wrap">
${body}
</main>
<footer class="site"><div class="wrap">
<p>${t.disclaimer}</p>
<a href="/privacy">${t.privacy}</a><span class="sep">·</span><a href="${GITHUB}">GitHub</a><span class="sep">·</span><a href="${RELEASES}">${t.releaseNotes}</a><span class="sep">·</span><a href="${TESTFLIGHT}">${t.betaLink}</a><span class="sep">·</span>© 2026 nemut.ai
</div></footer>
</body>
</html>`;
  const scriptSrc = script ? `'${await scriptHash(script)}'` : "'none'";
  return new Response(html, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=300",
      "content-security-policy":
        `default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; script-src ${scriptSrc}; ` +
        "base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}

const badge = () =>
  `<a class="badge" href="${APP_STORE}"><img src="/assets/app-store-en.svg" width="120" height="40" alt="${esc(TEXT.appStoreAlt)}"></a>`;

const paras = (list) => list.map((p) => `<p>${p}</p>`).join("\n");

// MARK: - /

function homePage() {
  const t = TEXT;
  const shots = t.shots
    .map((s) => `<li><figure><img src="/assets/shot-${s.file}.webp" width="552" height="1200" alt="${esc(s.alt)}" decoding="async"><figcaption>${esc(s.label)}</figcaption></figure></li>`)
    .join("\n");
  const faq = FAQ.map((f) => `<div><h3>${esc(f.q)}</h3><p>${f.a}</p></div>`).join("\n");
  const body = `
<section class="hero">
<picture><source srcset="/icon-dark.png" media="(prefers-color-scheme: dark)"><img class="hero-icon" src="/icon.png" width="112" height="112" alt=""></picture>
<h1>EffectDeck</h1>
<p class="lead">${t.tagline}</p>
<div class="actions">${badge()}<a class="btn gh" href="${GITHUB}">GitHub</a></div>
<p class="foss">${t.foss}</p>
</section>

<ul class="shots">
${shots}
</ul>

<div class="cols">
<section id="how">
<h2>${t.howTitle}</h2>
${paras(t.home)}
</section>
<section id="jsfx">
<h2>${t.jsfxTitle}</h2>
${paras(t.jsfx)}
<p class="links">${t.jsfxLinks.join("")}</p>
</section>
<section id="share">
<h2>${t.shareTitle}</h2>
${paras(t.share)}
</section>
<section id="support">
<h2>${t.supportTitle}</h2>
${paras(t.support)}
</section>
</div>

<section id="faq">
<h2>${t.faqTitle}</h2>
<div class="faq">
${faq}
</div>
</section>

<section id="about">
<h2>${t.aboutTitle}</h2>
${paras(t.about)}
</section>
`;
  return page({ title: t.title, body, canonical: `${ORIGIN}/`, width: "wide", ld: homeLd() });
}

// MARK: - /?p=

// バナーの app-argument に入れる今の URL。アプリ（ETFXDLink.route）は lang が付いていても読む。
// **クエリは字のまま使う。**searchParams を触ると %2B や / の符号が書き換わる。
const deckURL = (url) => `https://${DECK_HOST}${url.pathname}${url.search}`;

function chainPage(url) {
  const t = TEXT;
  const entries = chainEntries(url.searchParams.get("p"));
  let body;
  let banner = null;
  let description = "An effect chain shared from EffectDeck.";
  if (entries) {
    banner = deckURL(url);
    const names = entries.filter((e) => !e.section).map((e) => e.name);
    if (names.length) {
      description = `An effect chain shared from EffectDeck: ${names.slice(0, 8).join(", ")}${names.length > 8 ? ", …" : ""}`;
    }
    const items = entries
      .map((e) =>
        e.section
          ? `<li class="section">${esc(e.name)}</li>`
          : `<li${e.off ? ' class="off"' : ""}>${esc(e.name)}${e.off ? `<span class="tag">${t.off}</span>` : ""}</li>`)
      .join("");
    body = `
<h1>${t.chainTitle}</h1>
<p class="muted">${t.chainHowTo}</p>
<div class="actions">${badge()}</div>
<ul class="chain">${items}</ul>`;
  } else {
    body = `
<h1>${t.chainTitle}</h1>
<p>${t.unreadable}</p>
<div class="actions">${badge()}</div>`;
  }
  return page({ title: `${t.chainTitle} — EffectDeck`, body, banner, description });
}

// MARK: - Copy

// Copy ボタン。/j と /write で同じ書き方。**書けなければ中身を選択しておく**（手でコピーできる）。
const copyJS = (t, id) => `$("copy").addEventListener("click", async () => {
  try { await navigator.clipboard.writeText($(${JSON.stringify(id)}).textContent); $("copy").textContent = ${JSON.stringify(t.copied)}; }
  catch { const r = document.createRange(); r.selectNodeContents($(${JSON.stringify(id)})); const s = getSelection(); s.removeAllRanges(); s.addRange(r); }
});`;

// インラインの script は </script を含まないこと。
function inline(js) {
  if (/<\/script/i.test(js)) throw new Error("inline script must not contain </script");
  return js;
}

// MARK: - /j

// head の apple-itunes-app の直後で走る（page を見ること）。
// **app-argument は最初に同期で書く。**payload は # の後ろにあってサーバーからは入れられない。
// 中身を戻すのは待ってから。戻せなくてもバナーは付けたままにする（アプリが理由を出す）。
function jsfxScript(t) {
  // **decodeFXD を文字列で貼る。**test.mjs が試しているのと同じ関数。
  const js = `(() => {
const hash = location.hash;
if (hash.length > 1) document.querySelector('meta[name="apple-itunes-app"]').setAttribute("content", ${JSON.stringify(bannerPrefix)} + location.href);
const decode = (${decodeFXD.toString()});
const $ = (id) => document.getElementById(id);
const run = async () => {
let src;
try { src = await decode(hash.slice(1)); } catch { $("bad").hidden = false; return; }
const desc = /^desc:\\s*(.+)$/m.exec(src);
if (desc) { $("title").textContent = desc[1].trim(); document.title = desc[1].trim() + " — EffectDeck"; }
$("src").textContent = src;
$("ok").hidden = false;
${copyJS(t, "src")}
};
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", run); else run();
})();`;
  return inline(js);
}

function jsfxPage() {
  const t = TEXT;
  const body = `
<h1 id="title">JSFX</h1>
<div id="ok" hidden>
<p class="muted">${t.jsfxHowTo}</p>
<div class="actions">${badge()}</div>
<div class="src-head"><button class="btn quiet" id="copy" type="button">${t.copy}</button></div>
<pre id="src"></pre>
</div>
<div id="bad" hidden>
<p>${t.unreadable}</p>
<div class="actions">${badge()}</div>
</div>`;
  return page({
    title: "JSFX — EffectDeck", body, script: jsfxScript(t), width: "code",
    description: "A JSFX script shared from EffectDeck.",
  });
}

// MARK: - /write

// アプリの「Write with ChatGPT」と同じ依頼文を見せる。**字は links.js の CHATGPT_Q 1 か所から。**
// JS が無くても字は選べるし、Open ChatGPT はただのリンク。
function writeScript(t) {
  return inline(`(() => {
const $ = (id) => document.getElementById(id);
const run = () => {
${copyJS(t, "prompt")}
};
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", run); else run();
})();`);
}

function writePage() {
  const t = TEXT;
  const body = `
<h1>${t.writeTitle}</h1>
<p class="muted">${t.writePlan}</p>
<div class="src-head"><button class="btn quiet" id="copy" type="button">${t.copy}</button></div>
<pre class="prompt" id="prompt">${esc(CHATGPT_Q)}</pre>
<div class="actions"><a class="btn" href="${esc(CHATGPT)}">${t.openChatGPT}</a></div>
<p class="muted">${t.writeOther}</p>
<p>${t.writeReturn}</p>`;
  return page({
    title: `${t.writeTitle} — EffectDeck`, body, script: writeScript(t), canonical: `${ORIGIN}/write`,
    description: "A request to paste into ChatGPT so that it writes a JSFX effect for EffectDeck.",
  });
}

// MARK: - /privacy

function privacyPage() {
  const body = `
<h1>${PRIVACY.title}</h1>
<p class="muted">EffectDeck · nemut.ai</p>
${PRIVACY.body}
<p class="muted">${PRIVACY.updated}</p>`;
  return page({
    title: `${PRIVACY.title} — EffectDeck`, body, canonical: `${ORIGIN}/privacy`,
    description: "EffectDeck's privacy policy. nemut.ai collects no data; audio stays on the device.",
  });
}

function notFound() {
  const body = `<h1>404</h1><p>${TEXT.notFound}</p><p><a href="/">${TEXT.backHome}</a></p>`;
  return page({ title: "404 — EffectDeck", body, status: 404 });
}
