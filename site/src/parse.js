// リクエストから読むもの。Worker の外（test.mjs）でも動くように import を持たない。
//
// 2026-09-26 に日本語をやめた。**?lang= と Accept-Language は読まない。**
// 古いリンクに付いた ?lang=ja はそのまま英語のページになる。

// 共有リンクの p（素の base64 の JSON 配列、ETShareLink 参照）から名前だけ拾う。
// 読めなければ null。**ここで読めないものはアプリでも読めない**ので、バナーに app-argument も付けない。
export function chainEntries(p) {
  try {
    // URLSearchParams は生の + を空白にする。アプリは %2B で書くが、手で貼られたものに備える。
    const b64 = p.trim().replace(/ /g, "+");
    const bin = atob(b64);
    const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    const list = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    if (!Array.isArray(list)) return null;
    const out = [];
    for (const o of list.slice(0, 500)) {
      if (!o || typeof o !== "object" || typeof o.nm !== "string" || o.nm === "") continue;
      if (o.nm === "Section") {
        const cm = typeof o.cm === "string" ? o.cm : "";
        out.push({ section: true, name: cm ? `${cm} Section` : "Section" });
      } else {
        out.push({ section: false, name: o.nm, off: o.en === false });
      }
    }
    return out.length ? out : null;
  } catch {
    return null;
  }
}
