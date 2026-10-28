//  ComponentGallery.swift
//  共有の部品を ImageRenderer で絵にして、文字サイズ・外観・幅ごとに並べる。
//
//  **何も判定しない。**人が見るための絵（xcresult の添付 -> CI の artifact）を作るだけで、
//  落ちるのは絵が作れなかったとき（ImageRenderer が nil を返す・描画中のクラッシュ）だけ。
//
//  実アプリを起こして撮る画面全体は Tests/UI/AccessibilityGallery.swift。こちらは
//  EffeTuneDSP を持たずに組める部品（数値欄・通知の行・選択・電源）を、細かい刻みで見る。
//  **ImageRenderer は UIKit の部品（セグメント、TextField の中身）を正しく描かない**
//  （黄色い禁止マークの代用品になる）。そこは枠の寸法と折り返しだけ読むこと。
//
//  アプリをホストにして @testable で読むので、Debug 構成で建てる（CI の a11y がそう呼ぶ）。

import SwiftUI
import UIKit
import XCTest
@testable import EffectDeck

@MainActor
final class ComponentGallery: XCTestCase {

    // MARK: - 組み合わせ

    private struct Setting {
        let name: String
        let size: DynamicTypeSize
        let scheme: ColorScheme
        let width: CGFloat
    }

    /// 既定・大きめ・アクセシビリティの 3 と 5。幅は iPhone と、iPad の 2 列の右側くらい。
    private let settings: [Setting] = [
        Setting(name: "L-light-390", size: .large, scheme: .light, width: 390),
        Setting(name: "L-dark-390", size: .large, scheme: .dark, width: 390),
        Setting(name: "XXXL-light-390", size: .xxxLarge, scheme: .light, width: 390),
        Setting(name: "AX3-light-390", size: .accessibility3, scheme: .light, width: 390),
        Setting(name: "AX3-dark-390", size: .accessibility3, scheme: .dark, width: 390),
        Setting(name: "AX5-light-390", size: .accessibility5, scheme: .light, width: 390),
        Setting(name: "L-light-700", size: .large, scheme: .light, width: 700),
        Setting(name: "AX3-light-700", size: .accessibility3, scheme: .light, width: 700),
    ]

    // MARK: - 道具

    /// view を全組み合わせで絵にして添付する。
    private func gallery<V: View>(_ scene: String, @ViewBuilder _ content: () -> V) {
        for s in settings {
            let view = content()
                .padding(16)
                .frame(width: s.width, alignment: .leading)
                .background(s.scheme == .dark ? Color.black : Color.white)
                .environment(\.dynamicTypeSize, s.size)
                .environment(\.colorScheme, s.scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.uiImage, let png = image.pngData() else {
                XCTFail("\(scene)-\(s.name): ImageRenderer が絵を返さない")
                continue
            }
            let att = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            att.name = "\(scene)-\(s.name).png"
            att.lifetime = .keepAlways
            add(att)
            print("A11Y-RENDER \(scene)-\(s.name) \(Int(image.size.width))x\(Int(image.size.height))")
        }
    }

    // MARK: - 部品

    /// 数値欄。幅の長い値（単位つき）と短い値。
    func testValueBoxes() {
        gallery("valuebox") {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Gain"); Spacer(); ValueBox(text: "-12.5 dB") }
                HStack { Text("Frequency"); Spacer(); ValueBox(text: "20.00 kHz") }
                HStack { Text("Q"); Spacer(); ValueBox(text: "0.70") }
            }
        }
    }

    /// 打ち込める数値欄（TextField）。
    func testValueFields() {
        gallery("valuefield") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Frequency")
                    Spacer()
                    ETValueField(text: "1.00 kHz", label: "Frequency",
                                 editText: { "1000" }, commit: { _ in })
                }
                HStack {
                    Text("Gain")
                    Spacer()
                    ETValueField(text: "+4.5 dB", label: "Gain",
                                 editText: { "4.5" }, commit: { _ in })
                }
            }
        }
    }

    /// 通知の行。短い題と、長い説明・等幅の 1 行・ボタンつき。
    func testNoticeRows() {
        gallery("notice") {
            VStack(alignment: .leading, spacing: 12) {
                ETNoticeRow(systemImage: "checkmark.circle", tone: .active,
                            title: "Running", detail: nil)
                ETNoticeRow(systemImage: "exclamationmark.triangle", tone: .warning,
                            title: "Sample rate differs from the output",
                            detail: "The output is running at 44.1 kHz while the input is 48 kHz.",
                            mono: "AVAudioSessionErrorCodeBadParam (-50)",
                            actionTitle: "Retry", action: {})
                ETNoticeRow(systemImage: "info.circle", tone: .normal,
                            title: "Local audio only", detail: "Remote control is off.")
            }
        }
    }

    /// 3 択。実測つきと、無しの 2 行。
    func testSegmentedChoice() {
        gallery("segmented") {
            SegmentedHost()
        }
    }

    /// 選択肢の行（選ばれている・いない）。
    func testChoiceRows() {
        gallery("choicerow") {
            VStack(alignment: .leading, spacing: 12) {
                ETChoiceRow(title: "Automatic", note: "Follows the output device.",
                            selected: true, action: {})
                ETChoiceRow(title: "Manual", note: "Keeps the setting you choose.",
                            selected: false, action: {})
            }
        }
    }

    /// 電源（カード 1 枚の入切）と ON バッジ。
    func testPower() {
        gallery("power") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Compressor", isOn: .constant(true)).toggleStyle(.power).labelsHidden()
                    PowerBadge(isOn: true)
                    Text("Compressor")
                }
                HStack {
                    Toggle("Gate", isOn: .constant(false)).toggleStyle(.power).labelsHidden()
                    PowerBadge(isOn: false)
                    Text("Gate")
                }
            }
        }
    }

    /// カードの板（材質）に値の行を載せたところ。
    func testCardWithRows() {
        gallery("card") {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Threshold").etFont(size: 15); Spacer(); ValueBox(text: "-24.0 dB") }
                    HStack { Text("Ratio").etFont(size: 15); Spacer(); ValueBox(text: "4.0 : 1") }
                }
                .padding(12)
            }
        }
    }
}

/// ETSegmentedChoice は Binding を取るので、状態を持つ入れ物に包む。
private struct SegmentedHost: View {
    @State private var a = Mode.normal
    @State private var b = Mode.wide

    enum Mode: String, CaseIterable, Identifiable {
        case normal = "Normal", wide = "Wide", extreme = "Extreme"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ETSegmentedChoice(title: "Latency", values: Mode.allCases, label: { $0.rawValue },
                              detail: "23.4 ms", selection: $a)
            ETSegmentedChoice(title: "Buffer", values: Mode.allCases, label: { $0.rawValue },
                              selection: $b)
        }
    }
}
