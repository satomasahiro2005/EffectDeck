//  ETStorefrontGate.swift
//  このアプリをどの国の App Store から入れたかで、出してはいけない入口を隠す。
//
//  **中国本土（CHN）では ChatGPT の入口を出さない。**2026.09.28 の審査で
//  Guideline 5（中国の生成 AI の規制。ChatGPT は向こうの許可を持っていない）で落ちた。
//  隠すのは Write JSFX with ChatGPT（EffectPickerView の Plugins の面の一覧の頭と、空の面の表示の 2 か所）と
//  Build with ChatGPT…（EffectPickerView の Effects の面の一覧の頭と、PipelineView の空の鎖の表示。
//  プリセットの口でも ⋯ のメニューでもない）。
//  香港（HKG）・台湾（TWN）は対象外。
//
//  国は StoreKit の Storefront（ISO 3166-1 alpha-3）で見る。端末の地域設定では見ない
//  （規制はどの店から配ったかに掛かる）。まだ分からないうち（nil）は出す。
//  Xcode から入れた版や TestFlight では Storefront がその Apple ID の国になる。

import Observation
import StoreKit

@Observable @MainActor
final class ETStorefrontGate {
    static let shared = ETStorefrontGate()

    /// Storefront.countryCode。分かるまで nil。
    private(set) var countryCode: String?

    var allowsChatGPT: Bool { Self.allowsChatGPT(countryCode: countryCode) }

    nonisolated static func allowsChatGPT(countryCode: String?) -> Bool {
        countryCode?.uppercased() != "CHN"
    }

    private var watching = false

    /// 起動時に 1 度呼ぶ。Apple ID の国が変わったときも追う。
    func start() {
        guard !watching else { return }
        watching = true
        Task { @MainActor in
            countryCode = await Storefront.current?.countryCode
            for await storefront in Storefront.updates {
                countryCode = storefront.countryCode
            }
        }
    }
}
