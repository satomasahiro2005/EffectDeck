//  RoutePicker.swift
//  出力先を選ぶボタン。コントロールセンターを開かずに切り替えられる。
//  中身は AirPlay のルートピッカーそのもので、Bluetooth のイヤホンも
//  AirPlay の受け手もここに出る。

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
