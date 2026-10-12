//  ETShareLink.swift
//  EffeTune の共有リンクの読み書き。
//
//  形は単純で、`?p=` に UTF-8 の JSON をそのまま base64 にしたもの。
//  圧縮も URL-safe への置換も入らない（js/utils/pipeline-state-codec.js）。
//  中身はショート形式の配列（js/ui/pipeline/clipboard-manager.js:114 が
//  Array であることを要求している）。
//
//  web 版は受け取り側で base64 の文字集合を /^[A-Za-z0-9+/=]+$/ で検査するので、
//  こちらも素の base64 で書く。
//  **読むほうは広く受ける**（ETChainText.json(from:)）。ChatGPTなどが作ったリンクや
//  貼られた返事は、base64urlや改行入りで来ることがある。
//
//  **Foundationだけ。**書く側は鎖の段（ETChainNode）をPipelineStore.Loadedへ写してから書くので、
//  EffeTuneDSPを連れてこずに単体テストに入る（ShareLinkTests）。

import Foundation

enum ETShareLink {

    /// web 版の置き場。ここに `?p=` を付けたものが共有リンクになる。
    static let base = "https://effetune.frieve.com/effetune.html"

    /// こちらの置き場。**外から来たものを落とさずに渡すときはこちら。**
    ///
    /// 上流のリンク（`url(for:)`）は AU と JSFX を落とすか素通しの Volume に
    /// 置き換える。上流に同じものが無いので当然だが、**こちらどうしで渡すときに
    /// 落とす理由は無い。**中身の形も `?p=<base64>` も上流と同じにしてあるので、
    /// 読む側（`parse`）は同じ道で受けられる。違うのは宛先だけ。
    ///
    /// **effectdeck.nemut.ai で作る。**associated domain はここだけで、アプリの無い人には
    /// 同じ URL が公式ページになる。fxd.nemut.ai は人が打つための別名（effectdeck へ 301）で、
    /// こちらからは作らない。受けるのはどちらでもよい（ETFXDLink.route）。
    static let deckBase = "https://effectdeck.nemut.ai/"

    // MARK: - 書く

    /// Make a link which the official EffeTune web app can read.
    ///
    /// **共有の画面からは使わない。**共有はいつも `deckURL`。EffeTune へは effectdeck.nemut.ai の
    /// 鎖のページが同じ形に落として渡す（site/src/parse.js の effeTuneLink）。
    /// `effeTuneForm` を変えたら、あちらも揃える（site/test.mjs が同じ落とし方を見張る）。
    ///
    /// External processors are an EffectDeck extension and must never leak into
    /// an official EffeTune link. An in-place processor can simply disappear.
    /// A processor which routes between buses is replaced by a 0 dB Volume so
    /// that removing the AU does not also disconnect the remaining graph.
    static func url(for chain: [ETChainNode]) -> URL? {
        url(for: chain.map { PipelineStore.Loaded($0) })
    }

    static func url(for items: [PipelineStore.Loaded]) -> URL? {
        link(base: base, form: effeTuneForm(items))
    }

    /// **落とさずに渡す。**外から来たもの（AU / JSFX）も、図の見せ方も、
    /// 鎖の形もそのまま入る。受けられるのは EffectDeck だけ。
    ///
    /// JSFX が乗るのは鍵（`jsfx:<名前>`）だけで、**ソースは入らない**
    /// （DSP/DisplayParams.swift と ETJSFXHost の置き場を読むこと）。
    /// 受け取った側が同じ JSFX を持っていなければ、その段は解決できずに落ちる。
    /// 再配布にはならない。
    static func deckURL(for chain: [ETChainNode]) -> URL? {
        deckURL(for: chain.map { PipelineStore.Loaded($0) })
    }

    static func deckURL(for items: [PipelineStore.Loaded]) -> URL? {
        link(base: deckBase, form: PipelineStore.shortForm(items))
    }

    /// ショート形式を`<base>?p=<base64>`にする。
    private static func link(base: String, form: [[String: Any]]) -> URL? {
        guard !form.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: form,
                                                     options: [.withoutEscapingSlashes,
                                                               .sortedKeys]),
              var comps = URLComponents(string: base) else { return nil }

        // **`+` は自分で %2B にする。**
        // URLComponents は `+` をクエリの正しい文字と見て素通しするが、
        // 受け側の web 版は URLSearchParams で読むので `+` が空白に復号され、
        // ui-manager.js:573 と clipboard-manager.js:120 の
        // /^[A-Za-z0-9+/=]+$/ が落ちて error.invalidUrl になる。
        // 出るのは Section 名に ASCII 以外を入れたとき（UTF-8 のバイト並びが
        // base64 で `+` を生む位置に来る）で、ASCII 名だけだと出ない。
        // こちら（ETShareLink.parse）は URLComponents 経由なので読めてしまい、
        // 送った側では気づけない（ShareLinkTests が URLSearchParams と同じ読み方で見張る）。
        //
        // `/` はクエリでも `URLSearchParams` でもそのまま通るので触らない。
        // base64 に `&` `#` `?` は出ない。
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "%2B")
        comps.percentEncodedQuery = "p=" + encoded
        return comps.url
    }

    /// An upstream-compatible projection of an EffectDeck chain.
    /// The sound will necessarily differ where an external processor was used,
    /// but native effects and bus topology remain loadable by EffeTune.
    static func effeTuneForm(_ chain: [ETChainNode]) -> [[String: Any]] {
        effeTuneForm(chain.map { PipelineStore.Loaded($0) })
    }

    static func effeTuneForm(_ items: [PipelineStore.Loaded]) -> [[String: Any]] {
        let encoded = PipelineStore.shortForm(items)
        return zip(items, encoded).compactMap { item, entry in
            // Sectionの終端は印を外し、上流が組の終わりに使う素のSection("")にする。
            guard !item.externalID.isEmpty else { return PipelineStore.upstreamEntry(entry) }

            // With no bus crossing, bypassing the processor is deletion.
            guard item.inputBus != item.outputBus else { return nil }

            // A disabled routed node contributes nothing in EffectDeck, so its
            // replacement must also remain disabled. Routing and channel keys
            // use the official short-form spelling already present in entry.
            var passthrough: [String: Any] = [
                "nm": "Volume",
                "en": item.enabled,
                "vl": 0.0,
            ]
            for key in ["ib", "ob", "ch"] {
                if let value = entry[key] { passthrough[key] = value }
            }
            return passthrough
        }
    }

    // MARK: - 読む

    /// 共有リンクでも、`p=` の中身そのものでも、JSON そのものでも受ける。
    /// 人がクリップボードから貼るときに、どれが来るか分からないため。
    ///
    /// 範囲の外の値は寄せ、知らない段は外す（ETChainText.prepare）。
    /// 何を直したかを見せる所はparseCheckedを使う。
    static func parse(_ text: String, catalog: [ETEffect]) -> [PipelineStore.Loaded] {
        parseChecked(text, catalog: catalog).items
    }

    /// parseと同じものに、直したこと・落としたことの控えを付けて返す。
    /// `jsfx`を渡すと`{"jsfx":"<desc:の名前>"}`の段を取り込んであるJSFXで引く（CHAIN.md）。
    /// 渡さなければその段は置けず、控えのnotFoundに入る。
    static func parseChecked(_ text: String, catalog: [ETEffect],
                             jsfx: ETChainText.JSFXResolver? = nil)
        -> (items: [PipelineStore.Loaded], report: ETChainText.Report) {
        guard let json = ETChainText.json(from: text) else { return ([], ETChainText.Report()) }
        let prepared = ETChainText.prepare(json, catalog: catalog, jsfx: jsfx)
        return (PipelineStore.parse(prepared.json, catalog: catalog), prepared.report)
    }
}
