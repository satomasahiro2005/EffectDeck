//  VirtualRoomUIModel.swift
//  Virtual Room の画面が使う純粋な模型。
//
//  **音の正は Node.values と C++ kernel だけ。**ここに音響状態は持たない
//  （docs/virtual-room-design.md §47）。持つのは
//    - パラメータの短い鍵（§12 の ABI）
//    - 真上から見た図を描くための幾何
//    - 壁の外へ出た配置を図の上だけで内側へ寄せる計算（§53）
//  の 3 つ。
//
//  §53 のとおり、**保存値は書き換えない。**効く値へ寄せるのは kernel の仕事で、
//  ここは同じ規則で「いま実際に鳴っている配置」を描くためだけに真似る。

import CoreGraphics
import Foundation

enum ETVirtualRoom {

    /// 型名。§39 の `ed` マーカーにもこの綴りを使う。
    static let type = "VirtualRoomPlugin"

    /// §12 Parameter ABI。**順序も綴りも変えない。**
    enum Key {
        static let width = "rw"
        static let depth = "rd"
        static let height = "rh"
        static let listenerX = "lx"
        static let listenerY = "ly"
        static let listenerZ = "lz"
        static let speakerAngle = "sa"
        static let speakerDistance = "sd"
        static let speakerElevation = "se"
        static let roomAmount = "rm"
        static let decayScale = "ds"
        static let sideMaterial = "sm"
        static let frontMaterial = "fm"
        static let rearMaterial = "bm"
        static let floorMaterial = "fl"
        static let ceilingMaterial = "ce"
        static let earlyOrder = "eo"
        static let headRadius = "hr"
        static let pinnaAmount = "pa"
        static let headShadow = "hs"
        static let outputGain = "og"
        static let modelVersion = "mv"
        static let seedLow = "s0"
        static let seedHigh = "s1"
    }

    /// カードに常に出す 7 本（§8〜§10）。Advanced に入るものはここに含めない。
    static let basicKeys = [Key.width, Key.depth, Key.height,
                            Key.speakerAngle, Key.speakerDistance,
                            Key.roomAmount, Key.decayScale]

    /// §11 Advanced の並び。節ごとに分ける。
    static let listenerKeys = [Key.listenerX, Key.listenerY, Key.listenerZ]
    static let speakerAdvancedKeys = [Key.speakerElevation]
    static let surfaceKeys = [Key.sideMaterial, Key.frontMaterial, Key.rearMaterial,
                              Key.floorMaterial, Key.ceilingMaterial]
    static let binauralKeys = [Key.headRadius, Key.pinnaAmount, Key.headShadow]
    static let renderingKeys = [Key.earlyOrder]
    static let outputKeys = [Key.outputGain]

    /// 画面に出さないもの（§13）。`mv` は保存はするが操作させない。
    /// seed は専用の行（16 進表示 + Randomize）で扱うので汎用の行から外す。
    static let hiddenKeys: Set<String> = [Key.modelVersion, Key.seedLow, Key.seedHigh]

    // MARK: - Seed

    /// §12。Float32 は 32bit 整数を完全には表せないので上下 16bit に割る。
    static func seed(low: Float, high: Float) -> UInt32 {
        let l = UInt32(clamping: Int(low.rounded())) & 0xFFFF
        let h = UInt32(clamping: Int(high.rounded())) & 0xFFFF
        return (h << 16) | l
    }

    static func seedParts(_ seed: UInt32) -> (low: Float, high: Float) {
        (Float(seed & 0xFFFF), Float((seed >> 16) & 0xFFFF))
    }

    static func seedText(_ seed: UInt32) -> String {
        String(format: "%08X", seed)
    }

    // MARK: - 幾何

    /// 真上から見た配置。単位は m（listener だけ部屋に対する割合から直した実寸）。
    ///
    /// 座標は **x = 右、y = 奥**。部屋は (0,0) が左手前の角、
    /// (width, depth) が右奥の角。
    struct Layout {
        var width: Double
        var depth: Double
        var listener: CGPoint
        var left: CGPoint
        var right: CGPoint
        /// 一次反射が壁に当たる点。図の線を引くのに使う。
        var reflections: [CGPoint]
        /// §53 で内側へ寄せたか。寄せたときは図の見た目を変えて知らせる。
        var clamped: Bool
    }

    /// 壁から取る最低限の余白（m）。§53。
    static let margin = 0.2

    /// 保存値から、いま実際に鳴っている配置を組む。
    ///
    /// `listenerX` / `listenerY` は部屋寸法に対する割合（%）。
    /// `angle` は左右対称で、度。`distance` は listener からの距離（m）。
    static func layout(width: Double, depth: Double,
                       listenerX: Double, listenerY: Double,
                       angle: Double, distance: Double) -> Layout {
        let w = max(width, 2 * margin + 0.01)
        let d = max(depth, 2 * margin + 0.01)
        let lx = min(max(w * listenerX / 100, margin), w - margin)
        let ly = min(max(d * listenerY / 100, margin), d - margin)
        let listener = CGPoint(x: lx, y: ly)

        // スピーカーは listener の正面（+y）を基準に ±angle。
        let radians = angle * .pi / 180
        let maxDistance = maximumDistance(width: w, depth: d,
                                          listener: listener, radians: radians)
        let effective = min(distance, maxDistance)
        let dx = sin(radians) * effective
        let dy = cos(radians) * effective
        let left = CGPoint(x: lx - dx, y: ly + dy)
        let right = CGPoint(x: lx + dx, y: ly + dy)

        return Layout(width: w, depth: d, listener: listener,
                      left: left, right: right,
                      reflections: firstOrder(width: w, depth: d,
                                              listener: listener,
                                              left: left, right: right),
                      clamped: effective < distance - 1e-6)
    }

    /// スピーカーが壁の外へ出ない最大の距離（§53）。
    ///
    /// 左右対称なので、外へ出る先は「横の壁」と「前後の壁」だけ見れば足りる。
    private static func maximumDistance(width: Double, depth: Double,
                                        listener: CGPoint, radians: Double) -> Double {
        let sx = abs(sin(radians))
        let sy = cos(radians)
        var limit = Double.greatestFiniteMagnitude
        if sx > 1e-6 {
            // 左右どちらが先に当たるかは listener の寄り方で決まる。狭い側を取る。
            let room = min(listener.x, width - listener.x) - margin
            limit = min(limit, max(room, 0) / sx)
        }
        if sy > 1e-6 {
            let room = depth - listener.y - margin
            limit = min(limit, max(room, 0) / sy)
        } else if sy < -1e-6 {
            let room = listener.y - margin
            limit = min(limit, max(room, 0) / -sy)
        }
        return limit
    }

    /// 一次反射が当たる点。側壁 2 枚（左右のスピーカーそれぞれ）と前の壁。
    ///
    /// 鏡像法そのまま: 壁に対してスピーカーを折り返し、listener と結んだ線が
    /// 壁を切る所が反射点になる。
    private static func firstOrder(width: Double, depth: Double,
                                   listener: CGPoint,
                                   left: CGPoint, right: CGPoint) -> [CGPoint] {
        var points: [CGPoint] = []
        // 左の壁 (x = 0) と右の壁 (x = width)。
        points += mirrorX(0, source: left, listener: listener)
        points += mirrorX(width, source: right, listener: listener)
        // 前の壁 (y = depth)。左右両方。
        points += mirrorY(depth, source: left, listener: listener)
        points += mirrorY(depth, source: right, listener: listener)
        return points
    }

    private static func mirrorX(_ wall: Double, source: CGPoint,
                                listener: CGPoint) -> [CGPoint] {
        let image = CGPoint(x: 2 * wall - source.x, y: source.y)
        guard let hit = crossing(from: listener, to: image,
                                 value: { $0.x }, wall: wall) else { return [] }
        return [hit]
    }

    private static func mirrorY(_ wall: Double, source: CGPoint,
                                listener: CGPoint) -> [CGPoint] {
        let image = CGPoint(x: source.x, y: 2 * wall - source.y)
        guard let hit = crossing(from: listener, to: image,
                                 value: { $0.y }, wall: wall) else { return [] }
        return [hit]
    }

    private static func crossing(from a: CGPoint, to b: CGPoint,
                                 value: (CGPoint) -> Double,
                                 wall: Double) -> CGPoint? {
        let va = value(a), vb = value(b)
        guard abs(vb - va) > 1e-9 else { return nil }
        let t = (wall - va) / (vb - va)
        guard t > 0, t < 1 else { return nil }
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    // MARK: - 図の上で掴んだものを保存値へ戻す

    /// listener を掴んで動かした先を、部屋寸法に対する割合（%）へ直す。
    static func listenerPercent(_ point: CGPoint, width: Double, depth: Double)
        -> (x: Double, y: Double) {
        let x = min(max(point.x, margin), max(width - margin, margin))
        let y = min(max(point.y, margin), max(depth - margin, margin))
        return (x / max(width, 1e-6) * 100, y / max(depth, 1e-6) * 100)
    }

    /// スピーカーを掴んで動かした先を、角度（度）と距離（m）へ直す。
    ///
    /// **片方を動かすと反対側も対称に動く**（§7）ので、返すのは絶対値の角度。
    static func speakerPolar(_ point: CGPoint, listener: CGPoint)
        -> (angle: Double, distance: Double) {
        let dx = point.x - listener.x
        let dy = point.y - listener.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 1e-6 else { return (0, 0) }
        return (abs(atan2(dx, dy)) * 180 / .pi, distance)
    }
}
