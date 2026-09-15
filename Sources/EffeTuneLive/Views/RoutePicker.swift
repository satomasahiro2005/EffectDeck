//  RoutePicker.swift
//  出力先を選ぶボタン。中身は AirPlay のルートピッカーそのもの。
//
//  これはシステム全体のルートを動かすもので、「このアプリの出力先」ではない。
//  だから設定に「Output」として置くのは間違いだった（そこで選ぶと、
//  他のアプリが EffeTune へ向けていたアプリごとの上書きまで外れる）。
//
//  一方で「いま鳴っているアプリを EffeTune へ送る」のはまさにこの道具の用途なので、
//  音が来ていないときの案内に置いてある。コントロールセンターを開く代わりになる。

import SwiftUI
import AVKit

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
