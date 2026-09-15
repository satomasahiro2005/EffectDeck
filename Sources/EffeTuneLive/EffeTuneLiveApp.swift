//  EffeTuneLiveApp.swift
//  EffeTune Live — 他のアプリの音を受けて、EffeTune のエフェクトを通して出し直す。

import SwiftUI

@main
struct EffeTuneLiveApp: App {
    var body: some Scene {
        WindowGroup { PipelineView() }
    }
}
