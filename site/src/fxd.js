// effectdeck.nemut.ai/j#<payload> の中身を読む。
//
// payload は JSFX のソース（UTF-8）を raw DEFLATE で縮めて base64url（= なし）にしたもの。
// アプリ側は NSData.compressed(using: .zlib)（これが raw DEFLATE）で書く。
//
// **この関数はページに文字列として埋め込まれる**（worker.js が toString() で貼る）。
// 外の変数や import を参照しないこと。参照すると埋め込んだ先で落ちる。
// test.mjs も同じ関数を読むので、テストが通ったものがそのままページで動く。

// **受ける範囲はアプリの ETFXDLink.decode と同じにする。**ページで読めてアプリで読めない
// リンクを作らないため。上限は sourceLimit（64 KB）と payloadLimit（96K 字）。
export async function decodeFXD(payload, maxBytes = 64 * 1024, maxChars = 96 * 1024) {
  if (typeof payload !== "string") throw new Error("fxd: not a string");
  const text = payload;
  // **base64url の文字しか通さない。**= や + / の混じったもの、空白も拒む。
  if (text.length === 0 || text.length > maxChars ||
      !/^[A-Za-z0-9_-]+$/.test(text) || text.length % 4 === 1) {
    throw new Error("fxd: not base64url");
  }
  let b64 = text.replace(/-/g, "+").replace(/_/g, "/");
  b64 += "=".repeat((4 - (b64.length % 4)) % 4);
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);

  // **展開した量で打ち切る。**短い payload から大きく膨らむものを読み切らない。
  const reader = new Blob([bytes]).stream()
    .pipeThrough(new DecompressionStream("deflate-raw"))
    .getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > maxBytes) {
      await reader.cancel().catch(() => {});
      throw new Error("fxd: too large");
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) { out.set(c, at); at += c.length; }
  // UTF-8 として読めないものは拒む（置換文字で埋めて見せない）。
  const source = new TextDecoder("utf-8", { fatal: true }).decode(out);
  if (source.trim().length === 0) throw new Error("fxd: empty");
  return source;
}
