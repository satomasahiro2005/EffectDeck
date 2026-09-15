//  RoutePicker.swift
//  出力先を選ぶボタン。中身は AirPlay のルートピッカーそのもの。
//
//  **いまは何も出さない。**
//
//  AVRoutePickerView を画面に置くと、このアプリが共有の出力コンテキストへ参加する。
//  すると他のアプリが EffeTune を選んだときに、こちらのセッションまで一緒に
//  仮想デバイスへ引きずられる。実機のログに出ていた順番:
//
//    activating connection ... com.apple.coremedia.routediscoverer.xpc
//    AudioSession: pickable routes changed
//    AVRouting: AVOutputContext (FigRoutingContext) RouteConfigUpdated
//    → 出力先が EffeTune になる
//
//  そうなると 出力 → ドライバ → TCP → 自分の入力 → 出力 の環が閉じる。
//  float32 のまま回るので整数への丸めもクリップも起きず、レベルだけが上がり続けて
//  スピーカーには何も届かない。
//
//  出力先を変えたいときはコントロールセンターから。
//  中身を消さず空の View にしてあるのは、置いてあった場所と理由を残すため。

import SwiftUI

struct RoutePicker: View {
    var body: some View { EmptyView() }
}
