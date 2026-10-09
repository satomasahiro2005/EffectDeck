//  RemoteScannerView.swift
//  PC の EffeTune を LAN から操る PoC の画面側（DSP/RemoteMirror.swift）。
//
//    - RemoteToolbarButton     鎖の画面のツールバーのアイコン。押すと RemotePanelView を開く。
//                              つなぐ・切るはここでしない。状態（つなぎたい・つなぎ中・つながった）だけを絵で見せる
//    - RemotePanelView         アイコンから開くシート。中身は RemoteContent。入口はツールバーのアイコン・Remote Control の帯。設定画面では Remote の面（SettingsView が RemoteRows を並べる）
//    - RemoteContent           List と題と QR の読み取り（シート用）
//    - RemoteRows              状態（ETRemoteIntent.layout）ごとの行。**入切のスイッチは無い。**
//                              情報（PC）・設定（Options）・操作（Connect / Scan QR Code / Disconnect / Forget）を別の Section に分ける
//    - RemoteScannerView       PC の画面の QR（http://host:port/?t=…）を読む。VisionKit の
//                              DataScannerViewController（公開 API）。そのリンク以外の QR は拾わない
//    - ETRemoteMeasurementDim  PC の鎖を編集しているあいだ、PC の測定値を映していない Analyzer の図を沈める
//    - ETRemoteUnsupportedMark PC の EffeTune が持っていない効果の段に、送れないと出す（鎖には載せない）
//
//  **Analyzer の図を沈める訳。**編集しているあいだ鳴っているのは PC で、Analyzer の図が描くのは
//  この端末の音（Telemetry）。PC の音の図ではないので、読めない形にして押せなくする。
//  沈めるのは GraphCanvas（ほぼ全部の図の土台）と Pitch Meter の図だけで、つまみは PC へ送れるので残す。
//  EQ の曲線のような設計の図も GraphCanvas を使うが、印はカードが Analyzer のときしか立てない。
//  **Mirror Analyzers を入れて PC が telemetry を持っていれば沈めない。**図は PC の枠で描く
//  （RemoteMirror.mirroredTaps）。映す段に入った時点で手元の枠は捨ててあるので、
//  PC の枠が来るまでは Waiting のまま。PC の番号が無い段・PC が古い版・切のときは沈めたまま。

import AVFoundation
import SwiftUI
import VisionKit

// MARK: - ツールバー

/// アイコン。**観測するのはこのビューだけ**にして、PipelineToolbar 自体は RemoteMirror を見ない
/// （あちらは提示の途中の Menu を作り直さないよう、渡す値を絞ってある）。
/// 押してもつなぎも切りもしない。開くのはシートで、つなぐ・切る・つなぎ先の変更はそちらでする。
struct RemoteToolbarButton: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var mirror = RemoteMirror.shared
    let open: () -> Void

    init(open: @escaping () -> Void) {
        self.open = open
    }

    /// **控えの「つなぎたい」は起動をまたいで残る。**それで塗ると、PC の EffeTune が居なくても
    /// 起動した瞬間から青く、つながっているように見えた。塗るのは hello の返事を受けてから（ETRemoteIndicator）。
    private var indicator: ETRemoteIndicator {
        ETRemoteIndicator(wantsConnection: prefs.remoteWantsConnection, status: mirror.status)
    }

    var body: some View {
        styled(Button("Remote Control", systemImage: "dot.radiowaves.left.and.right", action: open))
            // つなぎたいのにつながっていない（つないでいる途中・つなぎ直しを待っている・応答が無い）あいだ脈を打つ。
            .symbolEffect(.pulse, isActive: indicator == .connecting)
            .accessibilityValue(mirror.statusText)
    }

    /// つながっているあいだは青く塗る。PC 側（EffeTune の見出しのアイコン）も入のとき青で塗るので合わせる。
    /// ガラスのツールバーでは foregroundStyle の色が乗らないことがあるので、塗りのある形にする。
    @ViewBuilder
    private func styled<Label: View>(_ button: Button<Label>) -> some View {
        if indicator == .live {
            button.buttonStyle(.borderedProminent).tint(.blue)
        } else {
            button
        }
    }
}

/// ナビゲーションバー中央の枠。ふだんは LiveStatusStrip、PC の鎖を編集しているあいだは
/// 「Remote Control」の札にして、押すとリモートのシートを開く。
/// リモート中にこの端末の遅れと CPU を出しても、鳴っているのは PC なので意味が無い。
/// iPhone ではツールバーにリモートのアイコンを置けない（幅が足りない）ので、ここが入口になる。
struct RemoteStatusSlot: View {
    @ObservedObject private var mirror = RemoteMirror.shared
    let io: AudioIO
    let open: () -> Void

    init(io: AudioIO, open: @escaping () -> Void) {
        self.io = io
        self.open = open
    }

    var body: some View {
        if mirror.isRemote {
            Button(action: open) {
                // 操っているのは PC の EffeTune。「Remote Control」ではツールバーの幅が足りない。
                Label("EffeTune", systemImage: "dot.radiowaves.left.and.right")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .buttonStyle(.plain)
            .accessibilityValue(mirror.statusText)
        } else {
            LiveStatusStrip(io: io)
        }
    }
}

// MARK: - シート

/// アイコンから開くシート。中身は RemoteContent（節は設定画面の Remote の面と同じ RemoteRows）。
struct RemotePanelView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RemoteContent()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        // 行が少ないので、画面の半分も要らない。上へ引けば広がるように .large も残す（RoutingView と同じ）。
        .presentationDetents([.medium, .large])
    }
}

/// Remote Control の画面の中身（List・題・QR の読み取り）。NavigationStack の中に置く。
/// ツールバーのシート（RemotePanelView）の中身。設定画面の Remote の面は同じ RemoteRows を自分の List に並べる。
/// QR の読み取りはここで出す（画面の上に重なる）。
///
/// **読み取りの .sheet は List に付ける。**List の中の RemoteRows に付けると節ごとに配られ、
/// 同じ scanning を見るシートが節の数だけできて、出した直後に閉じた
/// （設定画面の Remote の面。2026-10-09、QR を写していないと即座に閉じた）。
struct RemoteContent: View {
    @State private var scanning = false

    var body: some View {
        List {
            RemoteRows(scan: { scanning = true })
        }
        .navigationTitle("Remote Control")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $scanning) {
            RemoteScannerView { url in
                scanning = false
                RemoteMirror.shared.pair(url)
            }
        }
    }
}

/// Remote Control の行。**入切のスイッチは無い。**情報（PC・読むだけ）と設定（Options）と操作（ボタン）を
/// 別の Section にする。形は状態（ETRemoteIntent.layout）で決まる。
///
///   unpaired  Scan QR Code だけ
///   active    PC（Status・Address・EffeTune の版・食い違い）／ Options（Mirror Analyzers）／ Disconnect
///             形は控え（つなぎたい）で決まる。つなぎ直しを止める Disconnect は、つながる前にも要るので。
///             Status と版はいまのつなぎ（status・host）で、つながるまでは Connecting か Error と版なし
///   idle      PC（Address・前に見た EffeTune の版）／ Connect・Scan QR Code ／ Forget
///
/// List の中に置く前提。読み取りは scan で親が出す。
struct RemoteRows: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var mirror = RemoteMirror.shared
    let scan: () -> Void

    init(scan: @escaping () -> Void) {
        self.scan = scan
    }

    var body: some View {
        let intent = mirror.intent
        switch intent.layout {
        case .unpaired:
            Section {
                scanButton
            } header: {
                Text(Self.title)
            } footer: {
                Text(Self.qrTrademark)
            }
        case .active:
            Section(Self.title) {
                LabeledContent("Status") {
                    Text(mirror.statusText)
                        .foregroundStyle(.secondary)
                }
                addressRow
                // PC の版はつながっているあいだだけ（host は hello の返事から）。つなぎ直しを待つあいだに
                // 前に見た版（lastHost）を並べると、Connecting でもつながっているように読める（切断中と同じ理由）。
                if let host = mirror.host {
                    LabeledContent(host.name) {
                        Text(host.label)
                            .foregroundStyle(.secondary)
                    }
                }
                mismatchRows
            }
            // 測定値を送れる PC（features に telemetry を出すもの）にだけ出す。公式の EffeTune 2.13.0 は
            // telemetry も overlays も持たない（remote-v1）ので、そちらには節ごと出さない。
            if mirror.host?.supports("telemetry") == true {
                Section("Options") {
                    Toggle("Mirror Analyzers", isOn: $prefs.remoteMirrorAnalyzers)
                }
            }
            Section {
                Button("Disconnect") { mirror.disconnectByUser() }
            }
        case .idle:
            // 切断中は PC の情報を並べない（つないでいるように読める）。つなぎ先の名前はボタンに出す。
            Section {
                if intent.canConnect {
                    Button("Connect to \(connectTarget)") { mirror.connectToSaved() }
                }
                // 4401 のように、つながらなかった理由があるときだけ状態を出す。
                if case .error = mirror.status {
                    LabeledContent("Status") {
                        Text(mirror.statusText)
                            .foregroundStyle(.secondary)
                    }
                }
                scanButton
            } header: {
                Text(Self.title)
            } footer: {
                Text(Self.qrTrademark)
            }
            Section {
                Button("Forget", role: .destructive) { mirror.forget() }
            }
        }
    }

    /// 先頭の節の見出し。どの状態でも同じ（何を操る画面かを言う）。
    static let title = "EffeTune Remote Control"

    /// QR コードの商標表示。**Scan QR Code のある節（unpaired と idle の先頭）の footer に付ける。**
    /// 登録商標の持ち主は DENSO WAVE INCORPORATED（DENSO ではない）。字は引用符つきで一字一句この形。
    /// active の節には Scan QR Code が無いので付けない。About の footer にも置かない。
    static let qrTrademark = "“QR Code” is a registered trademark of DENSO WAVE INCORPORATED."

    /// 切断中の Connect に出すつなぎ先。ホスト名、無ければアドレスの host。
    private var connectTarget: String {
        if let name = mirror.lastHost?.hostName, !name.isEmpty { return name }
        return ETRemoteAddress.parse(prefs.remoteAddress)?.host ?? "PC"
    }

    private var scanButton: some View {
        Button("Scan QR Code", action: scan)
    }

    /// トークンは出さない。host:port だけ。
    @ViewBuilder
    private var addressRow: some View {
        if let address = ETRemoteAddress.parse(prefs.remoteAddress) {
            LabeledContent("Address") {
                Text("\(address.host):\(address.port)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// PC の EffeTune と dsp/ の版か効果の一覧が食い違うとき。送れない効果は段にも印が付く。
    @ViewBuilder
    private var mismatchRows: some View {
        if let mismatch = mirror.mismatch {
            LabeledContent("Version") {
                Text(mismatch.headline)
                    .foregroundStyle(.orange)
            }
            if let text = mismatch.missingOnHostText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let text = mismatch.missingHereText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - QR の読み取り

struct RemoteScannerView: View {
    /// 読めた接続先。http:// か ws:// で t の揃ったものだけが来る。
    let onFound: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ready = false

    init(onFound: @escaping (URL) -> Void) {
        self.onFound = onFound
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if ready {
                    RemoteDataScanner(onFound: onFound)
                        .ignoresSafeArea()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            // まだ訊いていなければ先に訊く。訊く前は isAvailable が偽を返しうる。
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            // 読めない端末・カメラを断られた。何も言わずに閉じる。
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                ready = true
            } else {
                dismiss()
            }
        }
    }
}

private struct RemoteDataScanner: UIViewControllerRepresentable {
    let onFound: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning, !context.coordinator.found else { return }
        try? scanner.startScanning()
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (URL) -> Void
        /// 1 回で止める。同じ QR を写している間は何度も来る。
        private(set) var found = false

        init(onFound: @escaping (URL) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !found else { return }
            for item in addedItems {
                guard case .barcode(let code) = item,
                      let text = code.payloadStringValue,
                      let url = URL(string: text),
                      ETRemoteAddress.pairingLink(url) != nil else { continue }
                found = true
                dataScanner.stopScanning()
                onFound(url)
                return
            }
        }
    }
}

// MARK: - Analyzer の図を沈める

extension EnvironmentValues {
    /// 真のあいだ、測った音を描く図（GraphCanvas・Pitch Meter）を沈めて押せなくする。
    /// 立てるのは ETRemoteMeasurementDim だけ。
    @Entry var etMeasurementDimmed: Bool = false
}

extension View {
    /// 図の範囲に掛ける。dimmed が偽なら何もしない。
    func etDimmedWhenMeasuring(_ dimmed: Bool) -> some View {
        self
            .saturation(dimmed ? 0 : 1)
            .opacity(dimmed ? 0.3 : 1)
            .allowsHitTesting(!dimmed)
    }
}

/// PEQ の図に重ねるスペクトラム（と After ⇄ Compare の札）を包む。PC の鎖を編集しているあいだは
/// PC の前後の枠を映している tap（RemoteMirror.mirroredTaps）だけ描く。手元の音は PC の音と関係ない。
/// 手元で使っているときは素通し。RemoteMirror を観測するのはここ（図の本体は観測しない）。
struct ETRemoteOverlayGate<Content: View>: View {
    let tap: UInt32
    let content: () -> Content
    @ObservedObject private var mirror = RemoteMirror.shared

    init(tap: UInt32, @ViewBuilder content: @escaping () -> Content) {
        self.tap = tap
        self.content = content
    }

    var body: some View {
        if !mirror.isRemote || mirror.mirroredTaps.contains(tap) {
            content()
        }
    }
}

/// カードに掛ける。Analyzer のカードで、PC の鎖を編集しているあいだ、PC の測定値を
/// 映していない段にだけ印を立てる。RemoteMirror を観測するのはここ（カードの本体は観測しない）。
struct ETRemoteMeasurementDim: ViewModifier {
    let applies: Bool
    let tap: UInt32
    @ObservedObject private var mirror = RemoteMirror.shared

    init(applies: Bool, tap: UInt32) {
        self.applies = applies
        self.tap = tap
    }

    func body(content: Content) -> some View {
        content.environment(\.etMeasurementDimmed,
                            applies && mirror.isRemote && !mirror.mirroredTaps.contains(tap))
    }
}

/// カードに掛ける。PC の鎖を編集しているあいだ、PC の EffeTune が持っていない効果の段に
/// host.unsupportedText を出す。その段は PC へ送らない（ETRemoteProjection.project）。
/// RemoteMirror を観測するのはここ（カードの本体は観測しない）。
struct ETRemoteUnsupportedMark: ViewModifier {
    let effect: String
    @ObservedObject private var mirror = RemoteMirror.shared

    init(effect: String) {
        self.effect = effect
    }

    func body(content: Content) -> some View {
        // safeAreaInset は中身が空でも spacing ぶん空けるので、出さないときは何も足さない。
        VStack(spacing: 4) {
            content
            if mirror.hostLacks(effect), let host = mirror.host {
                Text(host.unsupportedText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }
        }
    }
}
