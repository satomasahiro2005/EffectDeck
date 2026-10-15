//  SFZVoiceGraph.swift
//  SFZ Note Player の声の図（2.14.0）。鳴っている鍵を鍵盤に、強さ（1 秒で 1/e に落ちる）を棒で出す。
//
//  上流 plugins/others/sfz_note_player.js の drawGraph と _bindPreview。
//  縦横比は 5:1、狭いとき（iPhone の幅）は 3:1（createResponsiveGraph の aspectRatio / mobileAspectRatio）。
//  色は Normal なら trace（ここでは .tint）、Note Colors（cl = Rainbow）なら Note Spectrogram と同じ音名の色。
//
//  **触ると鳴る。**鍵盤の上なら強さ 100、棒の所なら上ほど強く、指を離すと止む（previewMidi / previewVelocity。
//  保存しない値）。上流は鳴らしている間 power の lease で休ませないので、こちらも EffeTuneDSP.sfzPreviewing で
//  休ませない（無音の入力でも鳴る）。触れるのは、段が入っていてバンクが読めているときだけ。

import QuartzCore
import SwiftUI

struct SFZVoiceGraph: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP
    /// 触って鳴らせるか（バンクが読めている・段が入っている・図だけの形でない）。
    let canPreview: Bool

    @ETTelemetryFeed private var telemetry
    @State private var display = ETSFZVoiceDisplay()
    @State private var width: CGFloat = 320
    @State private var previewMidi = -1

    private var lowest: Int { Int(value("mn", 28)) }
    private var highest: Int { max(lowest, Int(value("mx", 91))) }
    private var maxVoices: Int { Int(value("pl", 32)) }
    private var rainbow: Bool { node.display["cl"] == "Rainbow" }

    private func value(_ key: String, _ fallback: Float) -> Float {
        guard let p = node.spec.params.first(where: { $0.key == key }),
              node.values.indices.contains(p.offset), node.values[p.offset].isFinite else { return fallback }
        return node.values[p.offset]
    }

    var body: some View {
        let height = (width * (width < 500 ? 1.0 / 3.0 : 1.0 / 5.0)).rounded()
        let frame = telemetry.frame(tap: node.tapId, type: .sfzVoices)
        let now = CACurrentMediaTime()
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !display.isAnimating(now: now))) { _ in
            Canvas { context, size in
                draw(&context, size: size, now: CACurrentMediaTime())
            }
        }
        .frame(height: height)
        .overlay {
            if canPreview {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { touch in preview(at: touch.location, size: CGSize(width: width, height: height)) }
                        .onEnded { _ in stopPreview() })
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: frame?.sequence) { _, _ in
            guard let frame, let parsed = ETSFZVoiceFrame.parse(type: frame.type, version: frame.version,
                                                               payload: frame.payload) else { return }
            display.accept(parsed, now: CACurrentMediaTime())
        }
        .onChange(of: node.enabled) { _, enabled in if !enabled { display.clear(); stopPreview() } }
        .onChange(of: canPreview) { _, can in if !can { stopPreview() } }
        .onDisappear { stopPreview() }
        .accessibilityElement()
        .accessibilityLabel("Sounding SFZ notes and decaying velocity bars. Voices: \(display.active) / \(maxVoices)")
    }

    // MARK: 寸法

    private func layout(_ size: CGSize) -> (keys: [ETNoteAxisKey], gutter: CGFloat, blackDepth: CGFloat, edge: CGFloat) {
        let keys = ETNoteAxisKey.keys(lowest: lowest, highest: highest, length: Double(size.width))
        let depths = ETNoteKeyboard.depths(octaveLength: 12 * size.width / CGFloat(highest - lowest + 1),
                                           crossLength: size.height)
        return (keys, depths.gutter, depths.blackDepth, size.height - depths.gutter)
    }

    private func noteColor(_ midi: Int) -> Color? {
        guard rainbow else { return nil }
        let c = ETNoteKeyboard.noteColors[((midi % 12) + 12) % 12]
        return Color(red: c.r / 255, green: c.g / 255, blue: c.b / 255)
    }

    // MARK: 描く

    private func draw(_ context: inout GraphicsContext, size: CGSize, now: Double) {
        let (keys, gutter, blackDepth, edge) = layout(size)
        let narrow = size.width < 500
        // 強さの目盛り（32・64・96）。
        var grid = Path()
        for velocity in [32.0, 64.0, 96.0] {
            let y = edge * (1 - velocity / 127)
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: ETGraphShading.grid, lineWidth: 1)

        // 白鍵 → 棒 → 黒鍵の順（上流と同じ。黒鍵は白鍵の上に載る）。
        for key in keys where !key.black {
            let rect = CGRect(x: key.whiteStart, y: edge, width: key.whiteEnd - key.whiteStart, height: gutter)
            if display.counts[key.midi] > 0 {
                context.fill(Path(rect), with: noteColor(key.midi).map { GraphicsContext.Shading.color($0) } ?? ETGraphShading.curve)
            } else {
                context.fill(Path(rect), with: .color(Color(white: 0.93)))
            }
            context.stroke(Path(rect), with: ETGraphShading.muted, lineWidth: 0.5)
        }
        for key in keys where key.end > key.start {
            let bar = edge * CGFloat(display.velocity(key.midi, now: now))
            guard bar >= 0.5 else { continue }
            let rect = CGRect(x: key.start + 0.5, y: edge - bar, width: max(1, key.end - key.start - 1), height: bar)
            context.fill(Path(rect), with: noteColor(key.midi).map { GraphicsContext.Shading.color($0) } ?? ETGraphShading.curve)
        }
        for key in keys where key.black {
            let rect = CGRect(x: key.start, y: edge, width: key.end - key.start, height: blackDepth)
            if display.counts[key.midi] > 0 {
                context.fill(Path(rect), with: noteColor(key.midi).map { GraphicsContext.Shading.color($0) } ?? ETGraphShading.curve)
            } else {
                context.fill(Path(rect), with: .color(Color(white: 0.07)))
            }
        }

        // 鍵盤の C の音名。字は鍵の幅に収まる大きさ。
        let keySize = min(9, size.width / CGFloat(highest - lowest + 1))
        for key in keys where key.midi % 12 == 0 {
            context.draw(Text("C\(key.midi / 12 - 1)").font(.system(size: keySize)).foregroundStyle(Color(white: 0.07)),
                         at: CGPoint(x: (key.whiteStart + key.whiteEnd) / 2, y: size.height - 3), anchor: .bottom)
        }

        // 縦の名前と目盛りの字。
        var label = context
        label.translateBy(x: narrow ? 18 : 20, y: edge / 2)
        label.rotate(by: .degrees(-90))
        label.draw(Text("Velocity").font(.system(size: narrow ? 13 : 14)).foregroundStyle(.primary),
                   at: .zero, anchor: .bottom)
        for velocity in [32, 64, 96] {
            let y = edge * (1 - CGFloat(velocity) / 127)
            guard y >= 12, y + 6 <= edge else { continue }
            context.draw(Text("\(velocity)").font(.system(size: narrow ? 11 : 12)).foregroundStyle(.secondary),
                         at: CGPoint(x: narrow ? 46 : 80, y: y), anchor: .trailing)
        }

        // 右上の声の数。
        context.draw(Text("Voices: \(display.active) / \(maxVoices)")
                        .font(.system(size: narrow ? 11 : 12).monospacedDigit())
                        .foregroundStyle(.secondary),
                     at: CGPoint(x: size.width - 4, y: 4), anchor: .topTrailing)
    }

    // MARK: 試し弾き

    private func preview(at point: CGPoint, size: CGSize) {
        guard canPreview else { return }
        let (keys, gutter, blackDepth, edge) = layout(size)
        let x = min(max(point.x, 0), size.width)
        let y = min(max(point.y, 0), size.height)
        let keyboard = y >= edge
        let midi: Int?
        if keyboard {
            midi = ETNoteAxisKey.hit(keys, along: Double(x), across: Double(y - edge),
                                     gutter: Double(gutter), blackDepth: Double(blackDepth))?.midi
        } else {
            midi = min(highest, lowest + Int((x / size.width * CGFloat(highest - lowest + 1)).rounded(.down)))
        }
        guard let midi, midi != previewMidi else { return }
        let velocity = keyboard ? 100 : max(1, Int((127 * (1 - y / edge)).rounded()))
        previewMidi = midi
        dsp.sfzPreviewing = true
        send(midi: midi, velocity: velocity)
    }

    private func stopPreview() {
        guard previewMidi != -1 else { return }
        previewMidi = -1
        send(midi: -1, velocity: nil)
        dsp.sfzPreviewing = false
    }

    /// 強さを先に入れる（音の高さが変わった回にカーネルが強さを読む）。
    private func send(midi: Int, velocity: Int?) {
        let params = node.spec.params
        if let velocity, let pv = params.first(where: { $0.key == "pv" }) {
            dsp.setValue(Float(velocity), at: index, offset: pv.offset)
        }
        if let pm = params.first(where: { $0.key == "pm" }) {
            dsp.setValue(Float(midi), at: index, offset: pm.offset)
        }
    }
}
