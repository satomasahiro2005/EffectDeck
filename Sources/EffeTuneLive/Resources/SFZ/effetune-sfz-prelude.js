// Tools/sfzjs/prelude.js
// JavaScriptCore（ブラウザ API が無い素のコンテキスト）で、上流 js/sfz・js/sf2 の束ね（effetune-sfz.js）が
// 使うグローバルだけを補う。**束ねより先に評価する**。クラシックスクリプトで、import は無い。
//
// ・既にあるグローバルは触らない（typeof が 'undefined' のものだけ入れる）。
// ・Worker は入れない。上流は typeof Worker で NKSP のコンパイルを同じ場所で回す（script-worker.js:4）。
// ・window / document / fetch / WebAssembly も入れない。足りなければ ReferenceError で落ちる（それが狙い）。
//
// ホストが先に globalThis.__et を作っておく（無くてもテスト用の代わりで動く。下の「代わり」を参照）。
//   __et.sha256(bytes: Uint8Array) -> ArrayBuffer | Uint8Array   同期。無ければ JS 実装
//   __et.random(bytes: Uint8Array)                                 その場で埋める。無ければ Math.random（テスト専用）
//   __et.timer(callback, ms) -> id                                  ms 後に callback() を 1 回。無ければマイクロタスク
//   __et.cancelTimer(id)                                            省略可
//   __et.readRange(handle, offset, length) -> ArrayBuffer | Uint8Array   ファイルの範囲を同期で読む。
//                                                                   handle が Uint8Array/ArrayBuffer ならホスト無しで切り出す
//   __et.log(level: 'log'|'info'|'warn'|'error'|'debug', text)      省略可（無ければ捨てる）
//
// ホストのファイルは globalThis.__etShim.hostFile({handle, size, name, ...}) で File にする。
// 中身は読まずに範囲だけを覚え、slice() でも読まない。Blob の部品は __etShim.segments(blob) で
// {bytes} か {handle, offset, length} の並びとして取れる（container の書き出しが JS ヒープを通らないように）。
(function () {
  'use strict';
  const G = globalThis;
  const host = () => (typeof G.__et === 'object' && G.__et !== null ? G.__et : {});
  const missing = name => typeof G[name] === 'undefined';
  const define = (name, value) => {
    if (missing(name)) Object.defineProperty(G, name, { value, writable: true, configurable: true, enumerable: false });
  };
  // 型付き配列でも ArrayBuffer でも、その範囲だけを Uint8Array の目で見る（複写しない）
  const viewBytes = value => {
    if (value instanceof ArrayBuffer || Object.prototype.toString.call(value) === '[object ArrayBuffer]') return new Uint8Array(value);
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    return null;
  };

  // ---------------------------------------------------------------- UTF-8 / windows-1252
  const UTF8_LABELS = new Set(['unicode-1-1-utf-8', 'unicode11utf8', 'unicode20utf8', 'utf-8', 'utf8', 'x-unicode20utf8']);
  const W1252_LABELS = new Set(['ansi_x3.4-1968', 'ascii', 'cp1252', 'cp819', 'csisolatin1', 'ibm819', 'iso-8859-1', 'iso-ir-100',
    'iso8859-1', 'iso88591', 'iso_8859-1', 'iso_8859-1:1987', 'l1', 'latin1', 'us-ascii', 'windows-1252', 'x-cp1252']);
  // WHATWG の windows-1252（0x80-0x9F だけが違う。0x81・0x8D・0x8F・0x90・0x9D は C1 制御字のまま）
  const W1252_HIGH = [0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178];

  const codeUnitsToString = units => {
    let text = '';
    for (let i = 0; i < units.length; i += 8192) text += String.fromCharCode.apply(null, units.subarray(i, Math.min(i + 8192, units.length)));
    return text;
  };

  // WHATWG Encoding の UTF-8 デコーダ。不正な並びは最大の部分列ごとに U+FFFD 1 つ（fatal なら TypeError）
  function decodeUtf8(bytes, fatal, ignoreBOM) {
    const length = bytes.length;
    let index = 0;
    if (!ignoreBOM && length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) index = 3;
    const units = new Uint16Array(length + 1);
    let count = 0;
    let codePoint = 0, needed = 0, seen = 0, lower = 0x80, upper = 0xBF;
    const fail = () => {
      if (fatal) throw new TypeError('The encoded data was not valid for encoding utf-8');
      units[count++] = 0xFFFD;
    };
    while (index < length) {
      const byte = bytes[index];
      if (needed === 0) {
        index++;
        if (byte <= 0x7F) units[count++] = byte;
        else if (byte >= 0xC2 && byte <= 0xDF) { needed = 1; codePoint = byte & 0x1F; }
        else if (byte >= 0xE0 && byte <= 0xEF) {
          if (byte === 0xE0) lower = 0xA0;
          if (byte === 0xED) upper = 0x9F;
          needed = 2; codePoint = byte & 0xF;
        } else if (byte >= 0xF0 && byte <= 0xF4) {
          if (byte === 0xF0) lower = 0x90;
          if (byte === 0xF4) upper = 0x8F;
          needed = 3; codePoint = byte & 0x7;
        } else fail();
        continue;
      }
      if (byte < lower || byte > upper) {
        // 続きの字ではない。この字は捨て、同じ byte をもう一度頭から読む
        codePoint = needed = seen = 0; lower = 0x80; upper = 0xBF;
        fail();
        continue;
      }
      index++;
      lower = 0x80; upper = 0xBF;
      codePoint = (codePoint << 6) | (byte & 0x3F);
      if (++seen !== needed) continue;
      if (codePoint > 0xFFFF) {
        // 補助面はサロゲートペア。出力は入力より長くならない（4 byte → 2 単位）
        codePoint -= 0x10000;
        units[count++] = 0xD800 + (codePoint >> 10);
        units[count++] = 0xDC00 + (codePoint & 0x3FF);
      } else units[count++] = codePoint;
      codePoint = needed = seen = 0;
    }
    if (needed !== 0) fail();
    return codeUnitsToString(units.subarray(0, count));
  }

  class ETTextDecoder {
    #encoding; #fatal; #ignoreBOM;
    constructor(label = 'utf-8', options = {}) {
      const name = String(label).trim().toLowerCase();
      if (UTF8_LABELS.has(name)) this.#encoding = 'utf-8';
      else if (W1252_LABELS.has(name)) this.#encoding = 'windows-1252';
      else throw new RangeError(`The "${label}" encoding is not supported`);
      this.#fatal = Boolean(options && options.fatal);
      this.#ignoreBOM = Boolean(options && options.ignoreBOM);
    }
    get encoding() { return this.#encoding; }
    get fatal() { return this.#fatal; }
    get ignoreBOM() { return this.#ignoreBOM; }
    decode(input, options) {
      if (options && options.stream) throw new TypeError('TextDecoder stream decoding is not supported');
      if (input === undefined) return '';
      const bytes = viewBytes(input);
      if (!bytes) throw new TypeError('The "input" argument must be an instance of ArrayBuffer or ArrayBufferView.');
      if (this.#encoding === 'utf-8') return decodeUtf8(bytes, this.#fatal, this.#ignoreBOM);
      const units = new Uint16Array(bytes.length);
      for (let i = 0; i < bytes.length; i++) {
        const byte = bytes[i];
        units[i] = byte >= 0x80 && byte < 0xA0 ? W1252_HIGH[byte - 0x80] : byte;
      }
      return codeUnitsToString(units);
    }
    get [Symbol.toStringTag]() { return 'TextDecoder'; }
  }

  // 書き出す長さ。対にならないサロゲートは U+FFFD（3 byte）
  function utf8Length(text) {
    let length = 0;
    for (let i = 0; i < text.length; i++) {
      const unit = text.charCodeAt(i);
      if (unit < 0x80) length += 1;
      else if (unit < 0x800) length += 2;
      else if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length && (text.charCodeAt(i + 1) & 0xFC00) === 0xDC00) { length += 4; i++; }
      else length += 3;
    }
    return length;
  }
  // dest の残りに入る分だけ書く。{read（UTF-16 単位）, written}
  function utf8Write(text, dest) {
    let read = 0, written = 0;
    for (let i = 0; i < text.length; i++) {
      let unit = text.charCodeAt(i), size, units = 1;
      if (unit < 0x80) size = 1;
      else if (unit < 0x800) size = 2;
      else if (unit >= 0xD800 && unit <= 0xDFFF) {
        if (unit <= 0xDBFF && i + 1 < text.length && (text.charCodeAt(i + 1) & 0xFC00) === 0xDC00) {
          unit = 0x10000 + ((unit - 0xD800) << 10) + (text.charCodeAt(i + 1) - 0xDC00); size = 4; units = 2;
        } else { unit = 0xFFFD; size = 3; }
      } else size = 3;
      if (written + size > dest.length) break;
      if (size === 1) dest[written] = unit;
      else if (size === 2) { dest[written] = 0xC0 | (unit >> 6); dest[written + 1] = 0x80 | (unit & 0x3F); }
      else if (size === 3) {
        dest[written] = 0xE0 | (unit >> 12); dest[written + 1] = 0x80 | ((unit >> 6) & 0x3F); dest[written + 2] = 0x80 | (unit & 0x3F);
      } else {
        dest[written] = 0xF0 | (unit >> 18); dest[written + 1] = 0x80 | ((unit >> 12) & 0x3F);
        dest[written + 2] = 0x80 | ((unit >> 6) & 0x3F); dest[written + 3] = 0x80 | (unit & 0x3F);
      }
      written += size; read += units; i += units - 1;
    }
    return { read, written };
  }

  class ETTextEncoder {
    get encoding() { return 'utf-8'; }
    encode(input = '') {
      const text = String(input);
      const out = new Uint8Array(utf8Length(text));
      utf8Write(text, out);
      return out;
    }
    encodeInto(source, destination) {
      const dest = viewBytes(destination);
      if (!dest) throw new TypeError('The "dest" argument must be an instance of Uint8Array.');
      return utf8Write(String(source), dest);
    }
    get [Symbol.toStringTag]() { return 'TextEncoder'; }
  }

  define('TextDecoder', ETTextDecoder);
  define('TextEncoder', ETTextEncoder);

  // ---------------------------------------------------------------- SHA-256 と乱数
  const K256 = new Uint32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]);

  // ホストの __et.sha256 が無いとき（Node のテストなど）の代わり
  function sha256Js(bytes) {
    const length = bytes.length;
    const total = ((length + 9 + 63) >> 6) << 6;
    const padded = new Uint8Array(total);
    padded.set(bytes);
    padded[length] = 0x80;
    const view = new DataView(padded.buffer);
    view.setUint32(total - 8, Math.floor(length / 0x20000000), false);
    view.setUint32(total - 4, (length << 3) >>> 0, false);
    const h = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
    const w = new Uint32Array(64);
    const rotr = (x, n) => (x >>> n) | (x << (32 - n));
    for (let offset = 0; offset < total; offset += 64) {
      for (let i = 0; i < 16; i++) w[i] = view.getUint32(offset + i * 4, false);
      for (let i = 16; i < 64; i++) {
        const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
        const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
      }
      let a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
      for (let i = 0; i < 64; i++) {
        const t1 = (hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i]) | 0;
        const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) | 0;
        hh = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
      }
      h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
    const out = new Uint8Array(32);
    const outView = new DataView(out.buffer);
    for (let i = 0; i < 8; i++) outView.setUint32(i * 4, h[i], false);
    return out.buffer;
  }

  function digest(algorithm, data) {
    return new Promise(resolve => {
      const name = String(typeof algorithm === 'object' && algorithm !== null ? algorithm.name : algorithm).toUpperCase();
      if (name !== 'SHA-256') throw Object.assign(new Error(`Unrecognized algorithm name: ${name}`), { name: 'NotSupportedError' });
      const bytes = viewBytes(data);
      if (!bytes) throw new TypeError('The data argument must be an ArrayBuffer or ArrayBufferView.');
      const native = host().sha256;
      let result = typeof native === 'function' ? native(bytes) : sha256Js(bytes);
      if (result instanceof ArrayBuffer || Object.prototype.toString.call(result) === '[object ArrayBuffer]') resolve(result);
      else {
        const view = viewBytes(result);
        if (!view || view.length !== 32) throw new Error('The host SHA-256 returned an invalid result.');
        resolve(view.slice().buffer);
      }
    });
  }

  function getRandomValues(array) {
    if (!ArrayBuffer.isView(array) || array instanceof DataView || array instanceof Float32Array || array instanceof Float64Array)
      throw Object.assign(new TypeError('The data argument must be an integer-type TypedArray.'), { name: 'TypeMismatchError' });
    if (array.byteLength > 65536) throw Object.assign(new Error('The ArrayBufferView\'s byte length exceeds the number of bytes of entropy available.'), { name: 'QuotaExceededError' });
    const bytes = viewBytes(array);
    const native = host().random;
    if (typeof native === 'function') native(bytes);
    else for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
    return array;
  }

  if (missing('crypto')) define('crypto', {});
  try {
    const c = G.crypto;
    if (typeof c.subtle === 'undefined') c.subtle = {};
    if (typeof c.subtle.digest !== 'function') c.subtle.digest = digest;
    if (typeof c.getRandomValues !== 'function') c.getRandomValues = getRandomValues;
  } catch (error) { /* 読み取り専用の crypto がある場合は、そちらを使う */ }

  // ---------------------------------------------------------------- Blob / File
  // 部品は {bytes: Uint8Array}（複写済み）か {handle, offset, length}（ホストのファイルの範囲。読まない）
  const RANGE = Symbol('etHostRange');
  const segmentsOf = new WeakMap();
  const readHost = (handle, offset, length) => {
    const reader = host().readRange;
    let result;
    if (typeof reader === 'function') result = reader(handle, offset, length);
    else {
      const source = viewBytes(handle);
      if (!source) throw new Error('The host cannot read file ranges.');
      result = source.subarray(offset, offset + length);
    }
    const bytes = viewBytes(result);
    if (!bytes || bytes.length !== length) throw new Error('A file range could not be read.');
    return bytes;
  };
  const sizeOf = segments => segments.reduce((sum, segment) => sum + (segment.bytes ? segment.bytes.length : segment.length), 0);

  class ETBlob {
    #type;
    constructor(parts = [], options = {}) {
      const segments = [];
      for (const part of parts) {
        if (part && part[RANGE]) { if (part.length) segments.push({ handle: part.handle, offset: part.offset, length: part.length }); continue; }
        if (segmentsOf.has(part)) { segments.push(...segmentsOf.get(part)); continue; }
        const bytes = viewBytes(part);
        const copy = bytes ? bytes.slice() : new ETTextEncoder().encode(String(part));
        if (copy.length) segments.push({ bytes: copy });
      }
      segmentsOf.set(this, segments);
      this.#type = options && options.type !== undefined && /^[\x20-\x7E]*$/.test(String(options.type)) ? String(options.type).toLowerCase() : '';
    }
    get size() { return sizeOf(segmentsOf.get(this)); }
    get type() { return this.#type; }
    slice(start = 0, end = this.size, type = '') {
      const size = this.size;
      const clamp = (value, fallback) => {
        const number = value === undefined ? fallback : Math.trunc(Number(value)) || 0;
        return number < 0 ? Math.max(size + number, 0) : Math.min(number, size);
      };
      const first = clamp(start, 0), last = clamp(end, size);
      const parts = [];
      let position = 0;
      for (const segment of segmentsOf.get(this)) {
        const length = segment.bytes ? segment.bytes.length : segment.length;
        const from = Math.max(first - position, 0), to = Math.min(last - position, length);
        if (to > from) parts.push(segment.bytes ? { bytes: segment.bytes.subarray(from, to) }
          : { handle: segment.handle, offset: segment.offset + from, length: to - from });
        position += length;
      }
      const blob = new ETBlob([], { type });
      segmentsOf.set(blob, parts);
      return blob;
    }
    async bytes() {
      const segments = segmentsOf.get(this);
      const out = new Uint8Array(sizeOf(segments));
      let position = 0;
      for (const segment of segments) {
        const bytes = segment.bytes || readHost(segment.handle, segment.offset, segment.length);
        out.set(bytes, position);
        position += bytes.length;
      }
      return out;
    }
    async arrayBuffer() { return (await this.bytes()).buffer; }
    async text() { return decodeUtf8(await this.bytes(), false, false); }
    stream() { throw new TypeError('Blob.stream is not supported'); }
    get [Symbol.toStringTag]() { return 'Blob'; }
  }

  class ETFile extends ETBlob {
    #name; #lastModified;
    constructor(parts, name, options = {}) {
      super(parts, options);
      this.#name = String(name);
      this.#lastModified = options && options.lastModified !== undefined ? Math.trunc(Number(options.lastModified)) || 0 : Date.now();
    }
    get name() { return this.#name; }
    get lastModified() { return this.#lastModified; }
    get webkitRelativePath() { return ''; }
    get [Symbol.toStringTag]() { return 'File'; }
  }

  define('Blob', ETBlob);
  define('File', ETFile);

  // ホストが File を作るための口。size 0 でも作れる。webkitRelativePath は File の getter を持ち替える
  const hostRange = (handle, offset, length) => Object.freeze({ [RANGE]: true, handle, offset, length });
  const hostFile = ({ handle, size, name, lastModified = 0, type = '', webkitRelativePath = '' }) => {
    const file = new G.File([hostRange(handle, 0, size)], name, { lastModified, type });
    Object.defineProperty(file, 'webkitRelativePath', { value: String(webkitRelativePath), enumerable: false });
    return file;
  };
  Object.defineProperty(G, '__etShim', { value: Object.freeze({ range: hostRange, hostFile,
    segments: blob => (segmentsOf.get(blob) || []).map(segment => (segment.bytes ? { bytes: segment.bytes }
      : { handle: segment.handle, offset: segment.offset, length: segment.length })) }),
    writable: true, configurable: true, enumerable: false });

  // ---------------------------------------------------------------- タイマーと console
  let timerSerial = 0;
  const timers = new Map();
  define('setTimeout', function setTimeout(callback, delay, ...args) {
    if (typeof callback !== 'function') throw new TypeError('The callback must be a function.');
    const id = ++timerSerial;
    const entry = { hostId: null, cancelled: false };
    timers.set(id, entry);
    const run = () => {
      if (entry.cancelled) return;
      timers.delete(id);
      callback(...args);
    };
    const native = host().timer;
    if (typeof native === 'function') entry.hostId = native(run, Math.max(Number(delay) || 0, 0));
    else Promise.resolve().then(run);
    return id;
  });
  define('clearTimeout', function clearTimeout(id) {
    const entry = timers.get(id);
    if (!entry) return;
    entry.cancelled = true;
    timers.delete(id);
    const cancel = host().cancelTimer;
    if (typeof cancel === 'function' && entry.hostId !== null && entry.hostId !== undefined) cancel(entry.hostId);
  });
  define('queueMicrotask', callback => { Promise.resolve().then(callback); });

  if (missing('console')) {
    const say = level => (...args) => {
      const log = host().log;
      if (typeof log !== 'function') return;
      log(level, args.map(value => {
        if (typeof value === 'string') return value;
        if (value instanceof Error) return value.stack || `${value.name}: ${value.message}`;
        try { return JSON.stringify(value); } catch (error) { return String(value); }
      }).join(' '));
    };
    define('console', { log: say('log'), info: say('info'), warn: say('warn'), error: say('error'), debug: say('debug') });
  }

  // ---------------------------------------------------------------- MessageChannel（Worker の代わりの組）
  // 同じコンテキスト内の対。postMessage は構造化複製をせず、相手へマイクロタスクで渡す。
  // Worker 風に onmessage / onerror / onmessageerror / terminate() も持つ（上流の流し込みはそれで繋ぐ）。
  class ETMessagePort {
    #peer = null; #queue = []; #handler = null; #listeners = []; #started = false; #closed = false; #scheduled = false;
    onerror = null; onmessageerror = null;
    static pair() {
      const first = new ETMessagePort(), second = new ETMessagePort();
      first.#peer = second; second.#peer = first;
      return [first, second];
    }
    get onmessage() { return this.#handler; }
    set onmessage(handler) {
      this.#handler = typeof handler === 'function' ? handler : null;
      if (this.#handler) this.start();
    }
    addEventListener(type, listener) {
      if (type !== 'message' || typeof listener !== 'function' || this.#listeners.includes(listener)) return;
      this.#listeners.push(listener);
    }
    removeEventListener(type, listener) {
      if (type !== 'message') return;
      const at = this.#listeners.indexOf(listener);
      if (at >= 0) this.#listeners.splice(at, 1);
    }
    start() { this.#started = true; this.#schedule(); }
    postMessage(data) {
      if (this.#closed || !this.#peer || this.#peer.#closed) return;
      this.#peer.#queue.push(data);
      this.#peer.#schedule();
    }
    close() { this.#closed = true; this.#queue.length = 0; }
    terminate() { this.close(); }
    #schedule() {
      if (this.#scheduled || !this.#started || this.#closed || !this.#queue.length) return;
      this.#scheduled = true;
      Promise.resolve().then(() => {
        this.#scheduled = false;
        while (!this.#closed && this.#queue.length) {
          const event = { type: 'message', data: this.#queue.shift(), target: this, ports: [] };
          for (const listener of [this.#handler, ...this.#listeners]) {
            if (!listener) continue;
            try { listener.call(this, event); } catch (error) { if (typeof G.console === 'object') G.console.error(error); }
          }
        }
      });
    }
    get [Symbol.toStringTag]() { return 'MessagePort'; }
  }
  class ETMessageChannel {
    constructor() { [this.port1, this.port2] = ETMessagePort.pair(); }
  }
  define('MessageChannel', ETMessageChannel);

  // ---------------------------------------------------------------- AudioDecoder（SF3 の入口の印だけ）
  // sf2/asset.js は AudioDecoder.isConfigSupported の結果で圧縮 SoundFont を断る。
  // 復号はネイティブに置くので、それができるまでは「非対応」を返して上流の断り文に落とす。
  define('AudioDecoder', class AudioDecoder {
    static isConfigSupported() { return Promise.resolve({ supported: false }); }
  });
})();
