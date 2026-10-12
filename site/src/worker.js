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
import { chainEntries, effeTuneLink } from "./parse.js";
import { TEXT, FAQ, PRIVACY, LLMS_TXT } from "./text.js";
import { GUIDE, SOURCES } from "./guide.js";
import { GUIDE_SHOTS } from "./shots.js";
import { ORIGIN, homeLd } from "./seo.js";
import {
  DECK_HOST, LINK_HOST, DISCORD_HOST, DISCORD_INVITE, DISCORD, APP_ID, APP_STORE, APP_STORE_ID, GITHUB, RELEASES, TESTFLIGHT, TWITTER,
  CHATGPT, CHATGPT_Q,
} from "./links.js";
import badgeEn from "../assets/app-store-en.svg";
import ogImage from "../assets/og.png";
import ogDiscord from "../assets/og-discord.png";
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

// ナビの GitHub と Discord はアイコンにする（文字だと狭い画面で2行に折り返す）。図形は Simple Icons（CC0）。
const svgIcon = (d) => `<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="${d}"/></svg>`;
const ICON_GITHUB = svgIcon("M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12");
const ICON_DISCORD = svgIcon("M20.317 4.3698a19.7913 19.7913 0 00-4.8851-1.5152.0741.0741 0 00-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 00-.0785-.037 19.7363 19.7363 0 00-4.8852 1.515.0699.0699 0 00-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 00.0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 00.0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 00-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 01-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 01.0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 01.0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 01-.0066.1276 12.2986 12.2986 0 01-1.873.8914.0766.0766 0 00-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 00.0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 00.0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 00-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z");

// X・Discord・LINE・Slack・Facebook・Bluesky・Mastodon・Misskey 等のリンクプレビュー用クローラー。
// iMessage は facebookexternalhit と Twitterbot を名乗るのでここに入る。
const PREVIEW_BOT = /Twitterbot|facebookexternalhit|Facebot|Discordbot|Slackbot|LinkedInBot|TelegramBot|WhatsApp|Line\/|Bluesky|Cardyb|Mastodon|Misskey|SummalyBot|Pleroma|Akkoma|redditbot|Embedly|Iframely|Skype|vkShare|KakaoTalk/i;

function discordCard() {
  const title = "EffectDeck Base";
  const description = "The official EffectDeck Discord server. Questions, ideas and chains welcome.";
  const invite = esc(DISCORD_INVITE);
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>${title}</title>
<meta name="robots" content="noindex">
<meta name="description" content="${esc(description)}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="EffectDeck">
<meta property="og:title" content="${title}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:url" content="${DISCORD}">
<meta property="og:image" content="https://${DECK_HOST}/og-discord.png">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="EffectDeck Base, the official Discord server">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${title}">
<meta name="twitter:description" content="${esc(description)}">
<meta name="twitter:image" content="https://${DECK_HOST}/og-discord.png?v=2">
<meta name="twitter:image:alt" content="EffectDeck Base, the official Discord server">
</head><body><a href="${invite}">Join EffectDeck Base on Discord</a></body></html>`;
  return new Response(html, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=3600", "x-robots-tag": "noindex" },
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

    // **fxdb は Discord の招待リンクへ 302。**招待リンクは替わりうるので 301 にしない。
    // リンクのプレビューを作るクローラーにだけ、転送せず自前のOGPを返す（招待リンクのOGPは Discord の汎用のもの）。
    // X は robots.txt を読んでからカードを作るので、ここだけはクローラーにもテキストで返す。
    if (url.hostname === DISCORD_HOST) {
      if (url.pathname === "/robots.txt") {
        return new Response("User-agent: *\nAllow: /\n", {
          headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "public, max-age=3600" },
        });
      }
      if (PREVIEW_BOT.test(request.headers.get("user-agent") || "")) return discordCard();
      return new Response(null, {
        status: 302,
        headers: { location: DISCORD_INVITE, "cache-control": "no-store" },
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
    case "/guide":
    case "/guide/":
      return guideIndex();
    case "/about":
    case "/about/":
      return aboutPage();
    case "/write":
    case "/write/":
      return writePage();
    case "/privacy":
    case "/privacy/":
      return privacyPage();
    case "/privacy.html":
      return redirect(url, "/privacy");
    // 探す側への案内。共有の鎖（/?p=）と JSFX（/j）は入れない（noindex）。
    case "/robots.txt":
      return new Response(ROBOTS_TXT, { headers: textHeaders("text/plain; charset=utf-8") });
    case "/sitemap.xml":
      return new Response(SITEMAP_XML, { headers: textHeaders("application/xml; charset=utf-8") });
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
    case "/og-discord.png":
      return asset(ogDiscord, "image/png");
    case "/icon.png":
    case "/favicon.ico":
    case "/apple-touch-icon.png":
      return asset(iconLight, "image/png");
    case "/icon-dark.png":
      return asset(iconDark, "image/png");
  }
  const part = /^\/guide\/([a-z]+)\/?$/.exec(path);
  if (part) return guidePage(part[1]);
  const shot = /^\/assets\/shot-([a-z]+)\.webp$/.exec(path);
  if (shot && Object.hasOwn(SHOT_BYTES, shot[1])) return asset(SHOT_BYTES[shot[1]], "image/webp");
  return notFound();
}

const ROBOTS_TXT = `User-agent: *
Allow: /
Sitemap: ${ORIGIN}/sitemap.xml
`;

// 載せるのは公式のページだけ。共有の鎖や JSFX のページは人ごとに違うので入れない。
const SITEMAP_XML = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${["/", "/guide", ...GUIDE.pages.map((g) => `/guide/${g.slug}`), "/about", "/write", "/privacy"].map((p) => `  <url><loc>${ORIGIN}${p}</loc></url>`).join("\n")}
</urlset>
`;

function textHeaders(type) {
  return {
    "content-type": type,
    "cache-control": "public, max-age=3600",
    "x-content-type-options": "nosniff",
  };
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
nav.site a.icon{display:inline-flex;align-items:center}
nav.site a.icon svg{width:20px;height:20px;fill:currentColor}
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
[id]{scroll-margin-top:16px}
.hero h1{max-width:22ch;margin-inline:auto}
.hero .lead{max-width:40rem}
.btn.guide{display:inline-flex;align-items:center;height:48px;padding:0 20px;border-radius:10px}
.hero{position:relative;isolation:isolate;overflow:hidden;padding-bottom:40px}
.hero .actions+.actions{margin-top:0}
.hero-bg{z-index:-1;pointer-events:none}
.hero-bg{position:absolute;inset:0}
.hero-bg img{display:none;position:absolute;top:56px;width:230px;height:auto;border-radius:22px;opacity:.5;
  -webkit-mask-image:linear-gradient(#000 30%,transparent 85%);mask-image:linear-gradient(#000 30%,transparent 85%)}
@media (prefers-color-scheme:dark){.hero-bg img{opacity:.4}}
@media (min-width:1000px){.hero-bg .fan-0{display:block;left:0}.hero-bg .fan-2{display:block;right:0}}
.hero::after{content:"";position:absolute;left:0;right:0;bottom:0;height:140px;background:linear-gradient(transparent,var(--bg));z-index:-1;pointer-events:none}
.cards{list-style:none;padding:0;margin:16px 0 20px;display:grid;grid-template-columns:minmax(0,1fr);gap:12px;max-width:none}
.cards li{margin:0}
.cards a{display:block;height:100%;padding:16px 18px;border:1px solid var(--rule);border-radius:12px;background:var(--surface);color:inherit;text-decoration:none}
.cards a:hover{border-color:var(--accent)}
.cards h3{margin:0 0 4px}
.cards p{margin:0;color:var(--muted);font-size:.95rem}
.cards .num{display:block;font:600 .8rem/1.4 var(--mono);color:var(--accent);margin-bottom:6px}
@media (min-width:720px){.cards{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media (min-width:960px){.cards{grid-template-columns:repeat(3,minmax(0,1fr))}}
.toc{list-style:none;padding:0;margin:20px 0 0;display:flex;flex-wrap:wrap;gap:8px;max-width:none}
.toc li{margin:0}
.toc a{display:inline-block;padding:6px 12px;border:1px solid var(--rule);border-radius:999px;text-decoration:none;font-size:.9rem}
.toc a:hover{border-color:var(--accent)}
.chapter-n{display:block;font:600 .8rem/1.4 var(--mono);color:var(--accent);letter-spacing:.04em;margin-bottom:4px}
.chapter-n .opt{color:var(--muted);font-weight:500}
.goal{font-size:1.08rem}
.guide h3{margin:28px 0 8px}
ol{margin:0 0 12px;padding-left:1.4em;max-width:70ch}
.note{border-left:3px solid var(--rule);padding:2px 0 2px 14px}
.flow{display:flex;flex-wrap:wrap;align-items:center;gap:6px 8px;font:500 .9rem/1.4 var(--mono)}
.flow span.step{padding:6px 10px;border:1px solid var(--rule);border-radius:8px;background:var(--surface)}
.flow span.arr{color:var(--muted)}
.done{margin:20px 0 0;padding:12px 16px;border:1px solid var(--rule);border-radius:10px;background:var(--surface)}
.done p{margin:0 0 4px;font:600 .85rem/1.4 var(--mono);color:var(--muted)}
.done ul{margin:0}
.done li:last-child{margin-bottom:0}
table{border-collapse:collapse;width:100%;margin:0 0 16px;font-size:.95rem}
th,td{text-align:left;padding:8px 10px 8px 0;border-bottom:1px solid var(--rule);vertical-align:top}
th{font-weight:600}
td:first-child{white-space:nowrap;padding-right:16px}
.sources li{font-size:.95rem}
a.zoom{display:block;cursor:zoom-in;border-radius:18px}
a.zoom:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
dialog#lightbox{padding:0;border:0;margin:0;background:transparent;width:100vw;height:100dvh;max-width:100vw;max-height:100dvh;color:#fff}
dialog#lightbox[open]{display:flex;align-items:center;justify-content:center;gap:12px}
dialog#lightbox::backdrop{background:rgba(0,0,0,.88)}
#lightbox figure{margin:0;display:flex;flex-direction:column;align-items:center;min-width:0}
#lightbox img{display:block;max-height:calc(100dvh - 104px);max-width:min(92vw,620px);width:auto;height:auto;border-radius:22px;background:#f2f2f7;cursor:zoom-out}
#lightbox p{margin:12px 0 0;max-width:min(92vw,620px);font-size:.92rem;line-height:1.5;text-align:center;color:#e6edf3}
#lightbox button{flex:0 0 auto;width:44px;height:44px;border:0;border-radius:999px;background:rgba(255,255,255,.14);color:#fff;font:400 1.7rem/1 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;cursor:pointer}
#lightbox button:hover{background:rgba(255,255,255,.26)}
#lightbox .lb-close{position:fixed;top:14px;right:14px}
@media (max-width:640px){#lightbox .lb-prev,#lightbox .lb-next{display:none}}
.crumbs{font-size:.88rem;color:var(--muted);margin:0 0 12px}
.crumbs a{color:inherit}
.lead.goal{font-size:1.1rem;margin-bottom:8px}
.pager{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:12px;margin:48px 0 0;padding-top:24px;border-top:1px solid var(--rule)}
.pager a{display:block;padding:12px 16px;border:1px solid var(--rule);border-radius:10px;text-decoration:none;color:var(--fg);font-weight:600;line-height:1.4}
.pager a:hover{border-color:var(--accent)}
.pager span{display:block;font:600 .75rem/1.4 var(--mono);color:var(--muted);margin-bottom:4px}
.pager .next{grid-column:2;text-align:right}
.shotrow{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:20px 14px;margin:12px 0 24px}
.shotrow figure,figure.wide{margin:0}
figure.wide{margin:12px 0 24px;max-width:44rem}
.shotrow img{display:block;width:100%;height:auto;border-radius:18px;border:1px solid var(--rule);background:#f2f2f7}
@media (prefers-color-scheme:dark){.shotrow img{filter:brightness(.88)}}
.ph{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px;padding:10px;border:2px dashed var(--rule);border-radius:18px;background:repeating-linear-gradient(135deg,var(--surface) 0 10px,transparent 10px 20px);color:var(--muted);text-align:center}
.ph.phone{aspect-ratio:552/1200}
.ph.landscape{aspect-ratio:16/9;border-radius:12px}
.ph.thumb{aspect-ratio:16/10;border-radius:8px;margin:0 0 12px}
.ph svg{width:28px;height:28px;fill:none;stroke:currentColor;stroke-width:1.5;opacity:.7}
img.shot-thumb{display:block;width:100%;height:auto;aspect-ratio:16/10;object-fit:cover;border-radius:8px;margin:0 0 12px;border:1px solid var(--rule)}
img.shot-landscape{display:block;width:100%;height:auto;border-radius:12px;border:1px solid var(--rule)}
.ph .ph-id{font:500 .72rem/1.3 var(--mono);overflow-wrap:anywhere}
figcaption.cap{margin-top:8px;font-size:.82rem;line-height:1.45;color:var(--muted)}
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
  description = TEXT.description, canonical = null, width = "", ld = null, noindex = false,
  ogImage = OG_IMAGE, ogAlt = OG_ALT,
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
${noindex ? `<meta name="robots" content="noindex, follow">
` : ""}${canonical ? `<link rel="canonical" href="${esc(canonical)}">\n` : ""}<meta property="og:type" content="website">
<meta property="og:site_name" content="EffectDeck">
<meta property="og:locale" content="en_US">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
${canonical ? `<meta property="og:url" content="${esc(canonical)}">\n` : ""}<meta property="og:image" content="${ogImage}">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="${esc(ogAlt)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:site" content="@${TWITTER.split("/").pop()}">
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(description)}">
<meta name="twitter:image" content="${ogImage}">
<meta name="twitter:image:alt" content="${esc(ogAlt)}">
<meta name="theme-color" content="#fafafa" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0d1117" media="(prefers-color-scheme: dark)">
<link rel="icon" type="image/png" href="/icon.png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
${ld ? ldScript(ld) + "\n" : ""}<style>${CSS}</style>
</head>
<body${width ? ` class="${width}"` : ""}>
<header class="site"><div class="wrap">
<a class="brand" href="/"><picture><source srcset="/icon-dark.png" media="(prefers-color-scheme: dark)"><img src="/icon.png" alt=""></picture>EffectDeck</a>
<nav class="site"><a href="/guide">Guide</a><a href="/#faq">FAQ</a><a class="icon" href="${GITHUB}" aria-label="GitHub" title="GitHub">${ICON_GITHUB}</a><a class="icon" href="${DISCORD}" aria-label="Discord" title="Discord">${ICON_DISCORD}</a></nav>
</div></header>
<main class="wrap">
${body}
</main>
<footer class="site"><div class="wrap">
<p>${t.disclaimer}</p>
<a href="/about">About</a><span class="sep">·</span><a href="/privacy">${t.privacy}</a><span class="sep">·</span><a href="${GITHUB}">GitHub</a><span class="sep">·</span><a href="${DISCORD}">Discord</a><span class="sep">·</span><a href="${RELEASES}">${t.releaseNotes}</a><span class="sep">·</span><a href="${TESTFLIGHT}">${t.betaLink}</a><span class="sep">·</span>© 2026 nemut.ai
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
      ...(noindex ? { "x-robots-tag": "noindex, follow" } : {}),
    },
  });
}

const badge = () =>
  `<a class="badge" href="${APP_STORE}"><img src="/assets/app-store-en.svg" width="120" height="40" alt="${esc(TEXT.appStoreAlt)}"></a>`;

const paras = (list) => list.map((p) => `<p>${p}</p>`).join("\n");

// MARK: - 画像とプレースホルダー

// 撮るまでの枠。**id がそのまま撮ったときのファイル名**（assets/shot-<id>.webp）。説明は枠の下に出し、
// 本物に差し替えても説明は figcaption として残る。
const PH_ICON = `<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="10" r="2"/><path d="M21 16l-5-5-9 9"/></svg>`;
const placeholder = (id, kind) =>
  `<div class="ph ${kind}" role="img" aria-label="Screenshot to come: ${esc(id)}">${PH_ICON}<span class="ph-id">${esc(id)}</span></div>`;

// 撮ってある枠は本物（public/shots/<id>.webp、静的アセット）。一覧は tools/guide-shots.mjs が書く src/shots.js。
// 無い枠は撮るまでプレースホルダーのまま。
const SHOT_SIZE = { phone: [552, 1200], thumb: [640, 400] };
function picture(id, kind, alt) {
  if (!GUIDE_SHOTS.has(id)) return placeholder(id, kind);
  const [w, h] = SHOT_SIZE[kind] ?? [];
  const size = w ? ` width="${w}" height="${h}"` : "";
  return `<img class="shot-${kind}" src="/shots/${id}.webp"${size} alt="${esc(alt)}" loading="lazy" decoding="async">`;
}

// 押すと大きく開く画像（lightbox）。大きい版は public/shots/full/<id>.webp（tools/guide-shots.mjs）。
// 枠のまま（撮っていない）のものとカードの絵は包まない。
const zoomable = (html, href, caption) =>
  `<a class="zoom" href="${href}" data-cap="${esc(plain(caption))}">${html}</a>`;

// 縦長の画面 1 枚。TEXT.shots にある名前なら本物の画像。
function phoneShot([id, caption]) {
  const real = TEXT.shots.find((x) => x.file === id);
  let pic;
  if (real) {
    pic = zoomable(`<img src="/assets/shot-${real.file}.webp" width="552" height="1200" alt="${esc(real.alt)}" loading="lazy" decoding="async">`,
      `/assets/shot-${real.file}.webp`, caption);
  } else {
    pic = picture(id, "phone", plain(caption));
    if (GUIDE_SHOTS.has(id)) pic = zoomable(pic, `/shots/full/${id}.webp`, caption);
  }
  return `<figure>${pic}<figcaption class="cap">${caption}</figcaption></figure>`;
}

function wideShot([id, caption]) {
  let pic = picture(id, "landscape", plain(caption));
  if (GUIDE_SHOTS.has(id)) pic = zoomable(pic, `/shots/full/${id}.webp`, caption);
  return `<figure class="wide">${pic}<figcaption class="cap">${caption}</figcaption></figure>`;
}

// MARK: - lightbox

// 標準の <dialog>。Esc・背景・× で閉じる。←→ とボタンとスワイプで同じページの前後の画像へ。
// **CSP は script のハッシュで許す**（page の script）。外から何も読まない。
const LIGHTBOX = `<dialog id="lightbox" aria-label="Screenshot">
<button type="button" class="lb-close" data-close aria-label="Close">&times;</button>
<button type="button" class="lb-prev" data-prev aria-label="Previous">&lsaquo;</button>
<figure><img alt=""><p></p></figure>
<button type="button" class="lb-next" data-next aria-label="Next">&rsaquo;</button>
</dialog>`;

const LIGHTBOX_JS = inline(`(() => {
const run = () => {
  const links = [...document.querySelectorAll("a.zoom")];
  const d = document.getElementById("lightbox");
  if (!links.length || !d || !d.showModal) return;
  const img = d.querySelector("img"), cap = d.querySelector("p");
  let at = 0, x0 = null;
  const show = (n) => {
    at = (n + links.length) % links.length;
    const a = links[at];
    img.src = a.href;
    img.alt = a.querySelector("img")?.alt || "";
    cap.textContent = a.dataset.cap || "";
  };
  links.forEach((a, n) => a.addEventListener("click", (e) => {
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
    e.preventDefault(); show(n); d.showModal();
  }));
  d.addEventListener("click", (e) => {
    if (e.target.closest("[data-prev]")) show(at - 1);
    else if (e.target.closest("[data-next]")) show(at + 1);
    else d.close();
  });
  d.addEventListener("keydown", (e) => {
    if (e.key === "ArrowLeft") { e.preventDefault(); show(at - 1); }
    if (e.key === "ArrowRight") { e.preventDefault(); show(at + 1); }
  });
  d.addEventListener("touchstart", (e) => { x0 = e.touches[0].clientX; }, { passive: true });
  d.addEventListener("touchend", (e) => {
    if (x0 === null) return;
    const dx = e.changedTouches[0].clientX - x0; x0 = null;
    if (Math.abs(dx) > 50) show(at + (dx < 0 ? 1 : -1));
  });
  d.addEventListener("close", () => img.removeAttribute("src"));
};
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", run); else run();
})();`);

// alt に入れる字（説明の HTML からタグを外す）。
const plain = (html) => html.replace(/<[^>]*>/g, "").replace(/&[a-z]+;/g, " ");

// ガイドの 1 ページを指すカード。トップの Get started と /guide の目次で同じもの。
const partLabel = (i, g) => `Part ${i + 1}${g.tag ? ` · ${g.tag}` : ""}`;
const guideCards = () => GUIDE.pages
  .map((g, i) => `<li><a href="/guide/${g.slug}">${picture(`card-${g.slug}`, "thumb", "")}<span class="num">${partLabel(i, g)}</span><h3>${g.title}</h3><p>${g.card}</p></a></li>`)
  .join("\n");

// MARK: - /

function homePage() {
  const t = TEXT;
  // 見出しの左右の端に画面をまっすぐ置く（場所を取らない）。真ん中（fan-1）は文字と重なるので出さない。読む物ではないので alt は空。
  // App Store のバッジの周りは無地にする決まり。画面は文字の列の外（左右の端）にだけ置く。
  const backdrop = t.shots
    .map((s, i) => `<img class="fan-${i}" src="/assets/shot-${s.file}.webp" width="552" height="1200" alt="" decoding="async">`)
    .join("");
  const faq = FAQ.map((f) => `<div><h3>${esc(f.q)}</h3><p>${f.a}</p></div>`).join("\n");
  const body = `
<section class="hero">
<div class="hero-bg" aria-hidden="true">${backdrop}</div>
<picture><source srcset="/icon-dark.png" media="(prefers-color-scheme: dark)"><img class="hero-icon" src="/icon.png" width="112" height="112" alt=""></picture>
<h1>EffectDeck</h1>
<p class="lead">${t.tagline}</p>
<div class="actions">${badge()}</div>
<div class="actions"><a class="btn guide" href="/guide">${t.guideLink}</a><a class="btn gh" href="${GITHUB}">GitHub</a></div>
<p class="foss">${t.foss}</p>
</section>


<section id="start">
<h2>${t.startTitle}</h2>
<p>${t.startLead}</p>
<ol class="cards">
${guideCards()}
</ol>
</section>

<section id="why">
<h2>${t.whyTitle}</h2>
${paras(t.why)}
</section>

<div class="cols">
<section id="about">
<h2>${t.aboutTitle}</h2>
${paras(t.aboutShort)}
<p><a href="/about">${t.aboutMore}</a></p>
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
`;
  return page({ title: t.title, body, canonical: `${ORIGIN}/`, width: "wide", ld: homeLd() });
}

// MARK: - /guide

// 文面は guide.js。block の種類はそちらの頭に書いた。**script は置かない**（CSP は script-src 'none' のまま）。
// ページの h1 が題なので、ページの中の見出しは h2。
function guideBlock(k) {
  if (k.h) return `<h2${k.id ? ` id="${k.id}"` : ""}>${k.h}</h2>`;
  if (k.p) return `<p>${k.p}</p>`;
  if (k.note) return `<p class="note">${k.note}</p>`;
  if (k.ol) return `<ol>${k.ol.map((x) => `<li>${x}</li>`).join("")}</ol>`;
  if (k.ul) return `<ul>${k.ul.map((x) => `<li>${x}</li>`).join("")}</ul>`;
  if (k.flow) {
    const steps = k.flow.map((x) => `<span class="step">${x}</span>`).join(`<span class="arr" aria-hidden="true">&rarr;</span>`);
    return `<p class="flow">${steps}</p>`;
  }
  if (k.table) {
    const head = k.table.head.map((x) => `<th scope="col">${x}</th>`).join("");
    const rows = k.table.rows.map((r) => `<tr>${r.map((x) => `<td>${x}</td>`).join("")}</tr>`).join("");
    return `<table><thead><tr>${head}</tr></thead><tbody>${rows}</tbody></table>`;
  }
  if (k.shots) return `<div class="shotrow">${k.shots.map(phoneShot).join("")}</div>`;
  if (k.wide) return wideShot(k.wide);
  if (k.done) return `<div class="done"><p>You are there when</p><ul>${k.done.map((x) => `<li>${x}</li>`).join("")}</ul></div>`;
  throw new Error(`unknown guide block: ${JSON.stringify(k)}`);
}

// /guide は目次だけ。
function guideIndex() {
  const g = GUIDE;
  const body = `
<h1>${g.title}</h1>
<p class="lead">${g.lead}</p>
<ol class="cards">
${guideCards()}
</ol>`;
  return page({ title: `${g.title} — EffectDeck`, body, canonical: `${ORIGIN}/guide`, description: g.description, width: "wide",
    ogImage: `${ORIGIN}/og/guide.png`, ogAlt: "EffectDeck Guide, with three screens of the app" });
}

// /guide/<slug>。前へ／次へは GUIDE.pages の並び。
function guidePage(slug) {
  const pages = GUIDE.pages;
  const i = pages.findIndex((x) => x.slug === slug);
  if (i < 0) return notFound();
  const g = pages[i];
  const prev = pages[i - 1];
  const next = pages[i + 1];
  const pager = `<nav class="pager" aria-label="Guide">${
    prev ? `<a class="prev" rel="prev" href="/guide/${prev.slug}"><span>Previous</span>${prev.title}</a>` : ""}${
    next ? `<a class="next" rel="next" href="/guide/${next.slug}"><span>Next</span>${next.title}</a>` : ""}</nav>`;
  const body = `
<p class="crumbs"><a href="/guide">${GUIDE.title}</a> <span aria-hidden="true">/</span> ${partLabel(i, g)}</p>
<h1>${g.title}</h1>
<p class="lead goal">${g.goal}</p>
${g.blocks.map(guideBlock).join("\n")}
${pager}
${LIGHTBOX}`;
  return page({
    title: `${g.title} — EffectDeck`, body, canonical: `${ORIGIN}/guide/${g.slug}`, description: g.description,
    script: LIGHTBOX_JS,
    ogImage: `${ORIGIN}/og/guide-${g.slug}.png`, ogAlt: `EffectDeck Guide: ${g.title}`,
  });
}

// MARK: - /about

function aboutPage() {
  const t = TEXT;
  const body = `
<h1>${t.aboutPageTitle}</h1>
<h2 id="effetune">${t.aboutTitle}</h2>
${paras(t.about)}
<h2 id="port">${t.devTitle}</h2>
${paras(t.dev)}
<h2 id="sources">${SOURCES.title}</h2>
<ul class="sources">${SOURCES.items.map((x) => `<li>${x}</li>`).join("")}</ul>`;
  return page({
    title: `${t.aboutPageTitle} — EffectDeck`, body, canonical: `${ORIGIN}/about`,
    description: "EffectDeck runs EffeTune's open-source DSP by Yoshiyuki Kobayashi (Frieve-A). Where it comes from, how the iOS port is checked, and the sources behind the site.",
  });
}

// MARK: - /?p=

// バナーの app-argument に入れる今の URL。アプリ（ETFXDLink.route）は lang が付いていても読む。
// **クエリは字のまま使う。**searchParams を触ると %2B や / の符号が書き換わる。
const deckURL = (url) => `https://${DECK_HOST}${url.pathname}${url.search}`;

// アプリの「Export to EffeTune without N external effects」と同じ言い方。
const effeTuneLabel = (t, dropped) =>
  dropped === 0 ? t.openEffeTune
    : dropped === 1 ? t.openEffeTuneWithout1
    : t.openEffeTuneWithoutN.replace("{n}", String(dropped));

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
    // PC の EffeTune で開く人への口（parse.js の effeTuneLink）。外の段を落とすなら数を添える。
    const effetune = effeTuneLink(url.searchParams.get("p"));
    const toEffeTune = effetune
      ? `<a class="btn gh" href="${esc(effetune.url)}">${effeTuneLabel(t, effetune.dropped)}</a>`
      : "";
    body = `
<h1>${t.chainTitle}</h1>
<p class="muted">${t.chainHowTo}</p>
<div class="actions">${badge()}${toEffeTune}</div>
<ul class="chain">${items}</ul>`;
  } else {
    body = `
<h1>${t.chainTitle}</h1>
<p>${t.unreadable}</p>
<div class="actions">${badge()}</div>`;
  }
  return page({ noindex: true, title: `${t.chainTitle} — EffectDeck`, body, banner, description });
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
  return page({ noindex: true,
    title: "JSFX — EffectDeck", body, script: jsfxScript(t), width: "code",
    description: "A JSFX script shared from EffectDeck.",
  });
}

// MARK: - /write

// JSFXをChatGPTに書かせる依頼を見せるページ。トップのJSFX節と古いビルドのボタンから来る。
// アプリは2026-09-27からここを通らず、chatgpt.comを直に開く（EffectPickerView.writeJSFX）。
// **字は links.js の CHATGPT_Q 1 か所から。**
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
