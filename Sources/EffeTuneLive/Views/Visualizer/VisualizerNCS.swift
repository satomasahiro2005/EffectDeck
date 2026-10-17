//  VisualizerNCS.swift
//  NCS の要素と、曲の取得中の粒を Metal で描く。描き方は VisualizerNCS.metal（ncs_gl.py の移植）。
//  CoreGraphics の描き手（VisualizerRenderer）は、ここが渡す CGImage を要素の枠に置くだけ。
//
//  **GPU の仕事は面ごとの器（slot）に分けて、メインスレッドは待たない。**
//  1 回の step で、粒 → 密度（r16Float）→ 色（rgba16Float）→ 光彩（bgra8）の 3 つの描きと、
//  共有バッファへの blit を 1 本のコマンドに積んで投げる。結果は 3 本の輪の共有バッファの 1 つに書かれ、
//  終わったら ready に変わる。CGImage はこのバッファを写さずに指す（ETSpectrogramRing.image と同じ手）。
//  CPU は読むだけで、1 コマ遅れる。空いている出力が無い回は、その回の step を飛ばす。
//
//  **Metal が無い・GPU が使えない版は何も描かない**（アートワークは今のまま）。
//  アプリが背景のあいだ（PiP）に iOS が GPU の仕事を断ること（notPermitted）が想定されるので、
//  断られたら記録して、前に来るまで投げない。断られたかは実機のログ `ncs gpu refused` で見る。

import CoreGraphics
import Metal
import UIKit
import os

/// Metal の置き場に送る定数。VisualizerNCS.metal の NCSUniforms と同じ並び（96 バイト）。
private struct NCSUniforms {
    var flow0: SIMD4<Float>
    var flow1: SIMD4<Float>
    var flow2: SIMD4<Float>
    var color: SIMD4<Float>
    var screen: SIMD2<Float>
    var finalAudio: Float
    var audioRadius: Float
    var scale: Float
    var spacing: Float
    var densityScale: Float
    var gridN: UInt32
}

/// 端末に 1 つ。作れなければ nil（NCS は何も描かない）。
final class ETNCSGPU {

    static let shared: ETNCSGPU? = ETNCSGPU()
    fileprivate static let log = Logger(subsystem: "ai.nemut.effetune", category: "visualizer")

    let device: MTLDevice
    let queue: MTLCommandQueue
    let particles: MTLRenderPipelineState
    let color: MTLRenderPipelineState
    let glow: MTLRenderPipelineState
    let nearest: MTLSamplerState
    let linear: MTLSamplerState

    private struct Failure: Error {
        let reason: String
    }

    private init?() {
        assert(MemoryLayout<NCSUniforms>.size == 96, "NCSUniforms must match the Metal struct")
        guard let device = MTLCreateSystemDefaultDevice() else {
            Self.log.notice("ncs gpu unavailable: no device")
            return nil
        }
        guard let queue = device.makeCommandQueue() else {
            Self.log.notice("ncs gpu unavailable: no command queue")
            return nil
        }
        guard let library = device.makeDefaultLibrary() else {
            Self.log.notice("ncs gpu unavailable: no default library")
            return nil
        }
        func pipeline(_ vertex: String, _ fragment: String, _ format: MTLPixelFormat, additive: Bool) throws
            -> MTLRenderPipelineState {
            guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else {
                throw Failure(reason: "missing function \(vertex)/\(fragment)")
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = v
            descriptor.fragmentFunction = f
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            if additive {
                // 密度は足し込む（GLava の imageAtomicAdd の代わり）
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        func sampler(_ filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = filter
            descriptor.magFilter = filter
            descriptor.sAddressMode = .clampToEdge
            descriptor.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: descriptor)
        }
        do {
            particles = try pipeline("ncsParticles", "ncsDensity", .r16Float, additive: true)
            color = try pipeline("ncsQuad", "ncsColor", .rgba16Float, additive: false)
            glow = try pipeline("ncsQuad", "ncsGlow", .bgra8Unorm, additive: false)
        } catch {
            Self.log.notice("ncs gpu unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let nearest = sampler(.nearest), let linear = sampler(.linear) else {
            Self.log.notice("ncs gpu unavailable: no sampler")
            return nil
        }
        self.device = device
        self.queue = queue
        self.nearest = nearest
        self.linear = linear
    }
}

/// 面（アプリの画面・PiP）ごとに 1 つ。要素 UUID ごとの器（slot）を持つ。
@MainActor
final class ETVisualizerNCS {

    static var isSupported: Bool { ETNCSGPU.shared != nil }
    /// Metal があり、iOS に断られてもいない。偽のあいだは粒を描かず、アートワークを今のまま出す。
    var isAvailable: Bool { Self.isSupported && !refused }
    /// 面あたり。NCS の要素 2 つと、取得中のアートワークの要素 2 つ。
    static let maxSlots = 4
    /// 出力の輪の数。ready と投げ中を避けて、もう 1 つ空ける。
    private static let outputCount = 3

    @MainActor private final class Slot {
        let id: UUID
        /// 作り直したとき、前の器の遅れた返事を捨てるため。
        let token = UUID()
        let size: ETNCSGeometry.Size
        let density: MTLTexture
        let colorTexture: MTLTexture
        let finalTexture: MTLTexture
        let outputs: [MTLBuffer]
        var ready: Int?
        var inFlight: Set<Int> = []
        var audio = ETNCSAudio()
        let startedAt: Double
        var lastStep: Double?
        var lastSerial = -1
        var completedFrames = 0
        var gpuMilliseconds: Double = 0
        /// 大きさだけ替わって作り直したとき、新しい器の最初の絵が出るまで前の絵を見せる。
        var previous: Slot?

        init?(gpu: ETNCSGPU, id: UUID, size: ETNCSGeometry.Size, now: Double, carrying old: Slot? = nil) {
            func texture(_ format: MTLPixelFormat, _ usage: MTLTextureUsage) -> MTLTexture? {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: format, width: size.renderSide, height: size.renderSide, mipmapped: false)
                descriptor.usage = usage
                descriptor.storageMode = .private
                return gpu.device.makeTexture(descriptor: descriptor)
            }
            guard let density = texture(.r16Float, [.renderTarget, .shaderRead]),
                  let colorTexture = texture(.rgba16Float, [.renderTarget, .shaderRead]),
                  let finalTexture = texture(.bgra8Unorm, [.renderTarget]) else { return nil }
            let length = size.renderSide * size.renderSide * 4
            var outputs: [MTLBuffer] = []
            for _ in 0..<ETVisualizerNCS.outputCount {
                guard let buffer = gpu.device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
                outputs.append(buffer)
            }
            self.id = id
            self.size = size
            self.density = density
            self.colorTexture = colorTexture
            self.finalTexture = finalTexture
            self.outputs = outputs
            // 時間と音の状態は引き継ぐ（大きさが替わっても場が跳ばない・球がつぶれない）
            self.startedAt = old?.startedAt ?? now
            if let old {
                audio = old.audio
                lastStep = old.lastStep
                lastSerial = old.lastSerial
                previous = old.ready != nil ? old : old.previous
            }
        }
    }

    private var slots: [UUID: Slot] = [:]
    /// アプリが背景のあいだ iOS に断られた。前に来たら投げ直す。
    private var refused = false

    // MARK: - 絵

    /// いまの絵。この回の描きの中だけで使う（次の step は ready 以外の器に書く）。
    func images() -> [UUID: CGImage] {
        var result: [UUID: CGImage] = [:]
        // 断られているあいだは何も描かない（止まった絵を残さない）
        guard !refused else { return result }
        for (id, slot) in slots {
            // 作り直した直後は、新しい器の最初の絵が出るまで前の器の絵を使う
            let source = slot.ready != nil ? slot : slot.previous
            guard let source, let image = Self.image(of: source) else { continue }
            result[id] = image
        }
        return result
    }

    private static func image(of slot: Slot) -> CGImage? {
        guard let index = slot.ready else { return nil }
        let side = slot.size.renderSide
        guard let provider = CGDataProvider(dataInfo: nil, data: slot.outputs[index].contents(),
                                            size: side * side * 4, releaseData: { _, _, _ in }) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    // MARK: - 進める

    /// 1 枚ぶん進めて GPU に投げる。待たない。
    /// - Parameters:
    ///   - contentSide: 要素の内側の短い辺（画素）。描く大きさは ETNCSGeometry が決める。
    ///   - speed: 時間の進み。NCS の要素は 2.5、取得中は 1.0（ncs.glsl のまま）。
    ///   - bands: ETVisualizerAnalysis.ncsBands。serial が変わったときだけ音を進める。
    func step(_ id: UUID, contentSide: CGFloat, color: ETVisualizerColor, gain: Double, speed: Double,
              bands: [Float], serial: Int, now: Double) {
        guard let gpu = ETNCSGPU.shared,
              let size = ETNCSGeometry.size(contentSide: Double(contentSide)) else { return }
        if refused {
            guard UIApplication.shared.applicationState == .active else { return }
            refused = false
        }
        var found = slots[id]
        if found == nil || found?.size != size {
            if found == nil && slots.count >= Self.maxSlots { return }
            found = Slot(gpu: gpu, id: id, size: size, now: now, carrying: found)
            slots[id] = found
        }
        guard let slot = found else { return }
        // 空いている出力が無い回は飛ばす。待たない
        guard let index = (0..<Self.outputCount).first(where: { $0 != slot.ready && !slot.inFlight.contains($0) })
        else { return }

        let dt = slot.lastStep.map { now - $0 } ?? 1.0 / 60
        let fresh = serial != slot.lastSerial && bands.count == ETNCSAudio.bandCount
        let result = slot.audio.update(bands: fresh ? bands : nil, gain: Float(gain), dt: dt)
        slot.lastStep = now
        slot.lastSerial = serial

        let finalAudio = max(result.drive, ETNCSConstants.idle)
        let time = max(now - slot.startedAt, 0) * speed
        let flows = ETNCSGeometry.flowOffsets(time: time)
        let c = color.components
        var uniforms = NCSUniforms(
            flow0: flows.0, flow1: flows.1, flow2: flows.2,
            color: SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), 1),
            screen: SIMD2<Float>(Float(size.renderSide), Float(size.renderSide)),
            finalAudio: finalAudio, audioRadius: result.audioRadius, scale: size.scale,
            spacing: size.spacing, densityScale: size.densityScale, gridN: UInt32(size.gridN))

        guard let buffer = gpu.queue.makeCommandBuffer() else { return }
        func pass(_ target: MTLTexture) -> MTLRenderPassDescriptor {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            return descriptor
        }
        let stride = MemoryLayout<NCSUniforms>.stride

        // 1 回目: 粒 → 密度
        guard let first = buffer.makeRenderCommandEncoder(descriptor: pass(slot.density)) else { return }
        first.setRenderPipelineState(gpu.particles)
        first.setVertexBytes(&uniforms, length: stride, index: 0)
        first.drawPrimitives(type: .point, vertexStart: 0, vertexCount: size.gridN * size.gridN)
        first.endEncoding()

        // 2 回目: 密度 → 色
        guard let second = buffer.makeRenderCommandEncoder(descriptor: pass(slot.colorTexture)) else { return }
        second.setRenderPipelineState(gpu.color)
        second.setFragmentTexture(slot.density, index: 0)
        second.setFragmentSamplerState(gpu.nearest, index: 0)
        second.setFragmentBytes(&uniforms, length: stride, index: 0)
        second.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        second.endEncoding()

        // 3 回目: 光彩
        guard let third = buffer.makeRenderCommandEncoder(descriptor: pass(slot.finalTexture)) else { return }
        third.setRenderPipelineState(gpu.glow)
        third.setFragmentTexture(slot.colorTexture, index: 0)
        third.setFragmentSamplerState(gpu.linear, index: 0)
        third.setFragmentBytes(&uniforms, length: stride, index: 0)
        third.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        third.endEncoding()

        // 共有バッファへ
        guard let blit = buffer.makeBlitCommandEncoder() else { return }
        let side = size.renderSide
        blit.copy(from: slot.finalTexture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: side, height: side, depth: 1),
                  to: slot.outputs[index], destinationOffset: 0, destinationBytesPerRow: side * 4,
                  destinationBytesPerImage: side * side * 4)
        blit.endEncoding()

        slot.inFlight.insert(index)
        let token = slot.token
        buffer.addCompletedHandler { [weak self] finished in
            let status = finished.status
            let nsError = finished.error as NSError?
            let code = nsError?.code
            let isRefusal = nsError?.domain == MTLCommandBufferErrorDomain
                && nsError?.code == Int(MTLCommandBufferError.Code.notPermitted.rawValue)
            let milliseconds = (finished.gpuEndTime - finished.gpuStartTime) * 1000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.completed(id, token: token, index: index, status: status, code: code, isRefusal: isRefusal,
                                    milliseconds: milliseconds)
                }
            }
        }
        buffer.commit()
    }

    /// GPU の仕事が終わった（メインスレッド）。
    private func completed(_ id: UUID, token: UUID, index: Int, status: MTLCommandBufferStatus, code: Int?,
                           isRefusal: Bool, milliseconds: Double) {
        guard let slot = slots[id], slot.token == token else { return }
        slot.inFlight.remove(index)
        guard status == .completed else {
            if isRefusal {
                if !refused { ETNCSGPU.log.notice("ncs gpu refused (background)") }
                refused = true
                // 止まった絵が残らないように、出せる絵を全部捨てる
                for other in slots.values { other.ready = nil; other.previous = nil }
            } else {
                ETNCSGPU.log.notice("ncs gpu failed status=\(status.rawValue, privacy: .public) code=\(code ?? -1, privacy: .public)")
            }
            return
        }
        slot.ready = index
        slot.previous = nil
        slot.completedFrames += 1
        slot.gpuMilliseconds = slot.gpuMilliseconds == 0 ? milliseconds : slot.gpuMilliseconds * 0.9 + milliseconds * 0.1
        // 閾値を合わせるための記録だけ。画質を自分で替える仕組みは持たない
        if slot.completedFrames % 300 == 0 {
            let particles = slot.size.gridN * slot.size.gridN
            ETNCSGPU.log.notice("ncs gpu ms=\(slot.gpuMilliseconds, privacy: .public) side=\(slot.size.renderSide, privacy: .public) particles=\(particles, privacy: .public)")
        }
    }

    // MARK: - 器の管理

    /// ids 以外の器を捨てる。
    func keep(only ids: Set<UUID>) {
        for id in slots.keys where !ids.contains(id) { slots[id] = nil }
    }

    /// 全部捨てる。投げ中の仕事はコマンドが器を持っているので、そのまま終わる。
    func releaseAll() {
        slots.removeAll()
    }

    /// 面が回すたびに呼ぶ。NCS の要素と、取得中のアートワークの要素（NCS の要素が無い並びで、重みがあるとき）を進める。
    func step(ncsElements: [ETVisualizerElement], artworkElements: [ETVisualizerElement], layoutHasNCS: Bool,
              presentation: (weight: Double, color: ETVisualizerColor), pixelSize: CGSize, unit: CGFloat,
              analysis: ETVisualizerAnalysis, now: Double) {
        var used = Set<UUID>()
        func run(_ element: ETVisualizerElement) {
            guard used.count < Self.maxSlots else { return }
            var content = ETVisualizerRenderer.pixelRect(element.rect, pixelSize)
            if element.card { content = content.insetBy(dx: 8 * unit, dy: 8 * unit) }
            guard content.width >= 1, content.height >= 1 else { return }
            let isNCS = element.kind == .ncs
            step(element.id, contentSide: min(content.width, content.height),
                 color: isNCS ? element.color : presentation.color,
                 gain: isNCS ? element.ncsGain : 1,
                 speed: isNCS ? ETNCSConstants.elementSpeed : ETNCSConstants.identifyingSpeed,
                 bands: analysis.ncsBands, serial: analysis.ncsSerial, now: now)
            used.insert(element.id)
        }
        ncsElements.forEach(run)
        if presentation.weight > 0 && !layoutHasNCS { artworkElements.forEach(run) }
        keep(only: used)
    }
}
