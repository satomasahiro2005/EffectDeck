//  JSFXBench.swift
//  -ETBenchJSFX 1 で起動したときだけ、JSFX の実行系の速さを測って終わる（docs/jsfx-bench.md）。
//
//  **Debug と Beta（ET_BETA）だけ。**店の版にはこの口も台（Sources/Shared/ETJSFXBench.cpp）も
//  測るスクリプト（DebugJSFXBench、Scripts/embed_debug_jsfx.sh）も入らない。
//  測るあいだは音の経路を作らず、鎖・プリセット・設定にも触らない（EffeTuneLiveApp.init で
//  ほかの起動の仕事より先に分ける）。表は stdout、JSON は Documents/jsfx-bench.json。
//
//    xcrun devicectl device process launch --console --terminate-existing --device <UDID> \
//      ai.nemut.effetune -- -ETBenchJSFX 1 [-ETBenchSeconds 5] [-ETBenchScripts gain,fir] [-ETBenchGitSHA <sha>]

import Foundation

enum ETJSFXBenchMode {
    /// 起動の引数に -ETBenchJSFX 1 が在るか。店の版では常に false。
    static var requested: Bool {
        #if DEBUG || ET_BETA
        return UserDefaults.standard.bool(forKey: "ETBenchJSFX")
        #else
        return false
        #endif
    }

    #if DEBUG || ET_BETA
    /// 主スレッドの外で測る。終わったらプロセスを終える（照合が落ちたら 1）。
    static func start() {
        let thread = Thread { run() }
        thread.name = "JSFXBench"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private static func run() {
        let defaults = UserDefaults.standard
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("DebugJSFXBench", isDirectory: true),
              FileManager.default.fileExists(atPath: dir.path) else {
            print("JSFXBench: DebugJSFXBench is not in the bundle")
            fflush(stdout)
            exit(2)
        }
        #if DEBUG
        let config = "Debug"
        // YSFX は Debug で -O0。この数字は比べるのに使えない（docs/jsfx-bench.md）。
        print("JSFXBench: WARNING Debug build (YSFX -O0); use CONFIG=Beta for numbers")
        #else
        let config = "Beta"
        #endif
        var owned: [UnsafeMutablePointer<CChar>] = []
        func c(_ s: String?) -> UnsafePointer<CChar>? {
            guard let s, !s.isEmpty, let p = strdup(s) else { return nil }
            owned.append(p)
            return UnsafePointer(p)
        }
        defer { owned.forEach { free($0) } }

        var options = ETJSFXBenchOptions()
        ETJSFXBench_DefaultOptions(&options)
        let seconds = defaults.double(forKey: "ETBenchSeconds")
        if seconds > 0 { options.seconds = seconds }
        options.scriptDir = c(dir.path)
        options.scripts = c(defaults.string(forKey: "ETBenchScripts"))
        options.variants = c(defaults.string(forKey: "ETBenchVariants"))
        options.buildConfig = c(config)
        options.gitSHA = c(defaults.string(forKey: "ETBenchGitSHA"))
        options.compilerFlags = c("Xcode \(config): YSFX GCC_OPTIMIZATION_LEVEL default, app dspSettings -Os")

        let info = ProcessInfo.processInfo
        let thermalBefore = name(info.thermalState)
        guard let report = ETJSFXBench_Run(&options) else { exit(2) }
        defer { ETJSFXBench_Free(report) }
        let thermalAfter = name(info.thermalState)

        if let table = ETJSFXBench_Table(report) {
            print(String(cString: table), terminator: "")
            ETJSFXBench_FreeString(table)
        }
        let bundle = Bundle.main.infoDictionary ?? [:]
        let version = bundle["CFBundleShortVersionString"] as? String ?? ""
        let build = bundle["CFBundleVersion"] as? String ?? ""
        let extra = "\"runner\": \"app\", \"appVersion\": \"\(version)\", \"appBuild\": \"\(build)\", "
            + "\"thermalStateBefore\": \"\(thermalBefore)\", \"thermalStateAfter\": \"\(thermalAfter)\", "
            + "\"lowPowerMode\": \(info.isLowPowerModeEnabled)"
        print("thermal: \(thermalBefore) -> \(thermalAfter), low power: \(info.isLowPowerModeEnabled)")
        if let json = ETJSFXBench_JSON(report, extra) {
            let text = String(cString: json)
            ETJSFXBench_FreeString(json)
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let url = docs.appendingPathComponent("jsfx-bench.json")
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    print("json: \(url.path)")
                } catch {
                    print("JSFXBench: could not write \(url.path): \(error)")
                }
            }
        }
        let passed = ETJSFXBench_Passed(report)
        fflush(stdout)
        exit(passed ? 0 : 1)
    }

    private static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
    #endif
}
