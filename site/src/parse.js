// リクエストから読むもの。Worker の外（test.mjs）でも動くように import を持たない。
//
// 2026-09-26 に日本語をやめた。**?lang= と Accept-Language は読まない。**
// 古いリンクに付いた ?lang=ja はそのまま英語のページになる。

// 共有リンクの p（base64 の JSON、ETShareLink 参照）から名前だけ拾う。
// 読めなければ null。**ここで読めないものはアプリでも読めない**ので、バナーに app-argument も付けない。
// そのためアプリ（ETChainText.json(from:)）と同じ幅で読む。ChatGPT に作らせたリンクは
// base64url（- と _）や = の無いもの、途中で折り返したもので来ることがあり、
// JSFX を名前で指す段（{"jsfx":"<desc:の名前>"}、CHAIN.md）も持つ。ロング形式も受ける。
function decodeChain(p) {
  // URLSearchParams は生の + を空白にする。アプリは %2B で書くが、手で貼られたものに備える。
  // 改行やタブは折り返しなので外す。末尾の = が無くても atob は読む。
  const b64 = p.trim()
    .replace(/ /g, "+")
    .replace(/[\t\r\n]/g, "")
    .replace(/-/g, "+")
    .replace(/_/g, "/");
  const bin = atob(b64);
  const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}

export function chainEntries(p) {
  try {
    const json = decodeChain(p);
    const list = Array.isArray(json) ? json : Array.isArray(json?.pipeline) ? json.pipeline : null;
    if (!list) return null;
    const out = [];
    for (const o of list.slice(0, 500)) {
      if (!o || typeof o !== "object") continue;
      const off = (o.enabled ?? o.en) === false;
      if (typeof o.jsfx === "string" && o.jsfx !== "") {
        out.push({ section: false, name: o.jsfx, off });
        continue;
      }
      const nm = o.name ?? o.nm;
      if (typeof nm !== "string" || nm === "") continue;
      if (nm === "Section") {
        const cm = o.parameters?.cm ?? o.cm;
        const named = typeof cm === "string" && cm !== "";
        // アプリが置いた終端（"rr": true）は段ではないので出さない。戻す条件はアプリと同じ
        // （PipelineForm.parse: 印があり、名前が無く、入っているときだけ）。
        if (o.rr === true && !named && !off) continue;
        out.push({ section: true, name: named ? `${cm} Section` : "Section" });
      } else {
        out.push({ section: false, name: nm, off });
      }
    }
    return out.length ? out : null;
  } catch {
    return null;
  }
}

// EffeTune の Web 版へ渡すリンク。**アプリの ETShareLink.effeTuneForm と同じ形に落とす。**
// アプリは共有をいつも effectdeck.nemut.ai のリンクで出すので、PC の EffeTune で開く人はこのページから渡る。
//   - AU・JSFX（external・名前で指す jsfx）は上流に無い。バスを跨がないものは消し、
//     跨ぐものは素通しの Volume に置き換えて、残りの鎖の繋がりを切らない
//   - Section の終端の印（rr）は外す。上流は素の Section("") を組の終わりに使う
// 返すのは { url, dropped }。dropped は落とした・置き換えた外の段の数（ボタンの字に添える）。
// 上流が読むのはショート形式の配列だけ（clipboard-manager.js）。ロング形式や、落とした後に
// 何も残らないものは null（ボタンを出さない）。
// base64 は素の文字集合で書き、+ は %2B にする（上流は URLSearchParams で読み、/^[A-Za-z0-9+/=]+$/ で検査する）。
export const EFFETUNE_APP = "https://effetune.frieve.com/effetune.html";

export function effeTuneLink(p) {
  try {
    const json = decodeChain(p);
    if (!Array.isArray(json)) return null;
    const out = [];
    let dropped = 0;
    for (const o of json) {
      if (!o || typeof o !== "object") continue;
      const external = (typeof o.external === "string" && o.external !== "")
        || (typeof o.jsfx === "string" && o.jsfx !== "");
      if (!external) {
        if (typeof o.nm !== "string" || o.nm === "") continue;
        // rr（終端の印）と automation（音量に追従するキーフレーム）は EffectDeck だけのもの。
        const { rr, automation, ...rest } = o;
        out.push(rest);
        continue;
      }
      dropped++;
      if ((o.ib ?? 0) === (o.ob ?? 0)) continue;
      const passthrough = { nm: "Volume", en: o.en ?? true, vl: 0 };
      for (const key of ["ib", "ob", "ch"]) if (o[key] !== undefined) passthrough[key] = o[key];
      out.push(passthrough);
    }
    if (!out.length) return null;
    const bytes = new TextEncoder().encode(JSON.stringify(out));
    // 1 字ずつつなぐ。fromCharCode(...bytes) は長い鎖で引数の上限を越える。
    let bin = "";
    for (const b of bytes) bin += String.fromCharCode(b);
    return { url: `${EFFETUNE_APP}?p=${btoa(bin).replace(/\+/g, "%2B")}`, dropped };
  } catch {
    return null;
  }
}
