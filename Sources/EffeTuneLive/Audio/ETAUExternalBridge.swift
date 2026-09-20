// ETAUExternalBridge.swift
// Realtime-safe AUAudioUnit.renderBlock -> ETExternalProcessor bridge.

import AVFoundation
import AudioToolbox

@MainActor
final class ETAUExternalBridge {
    static let shared = ETAUExternalBridge()

    enum BridgeError: LocalizedError {
        case noSlot
        case unsupportedFormat(Double, Int)

        var errorDescription: String? {
            switch self {
            case .noSlot:
                return "The external processor limit is 8."
            case .unsupportedFormat(let rate, let channels):
                return "This Audio Unit does not support \(Int(rate)) Hz / \(channels) channels."
            }
        }
    }

    private var indices: [String: UInt8] = [:]
    private var adapters: [String: Adapter] = [:]
    // C descriptors are immutable and intentionally retained for process
    // lifetime. Keep their Swift contexts alive by the same rule.
    private var retired: [Adapter] = []

    private init() {}

    func reserve(instanceID: String) throws -> UInt8 {
        if let index = indices[instanceID] { return index }
        let used = Set(indices.values)
        guard let index = (0..<UInt8(8)).first(where: { !used.contains($0) }) else {
            throw BridgeError.noSlot
        }
        indices[instanceID] = index
        return index
    }

    @discardableResult
    func install(_ unit: AUAudioUnit, instanceID: String, sampleRate: Double,
                 channels: Int, maxFrames: Int) throws -> UInt8 {
        let index = try reserve(instanceID: instanceID)
        let adapter = try Adapter(unit: unit, sampleRate: sampleRate,
                                  channels: channels, maxFrames: maxFrames)
        if let old = adapters.updateValue(adapter, forKey: instanceID) {
            retired.append(old)
        }
        var descriptor = adapter.descriptor
        withUnsafePointer(to: &descriptor) {
            ETPipeline_SetExternalProcessorAt(UInt32(index), $0)
        }
        return index
    }

    /// Install a host-neutral processor (currently JSFX) into the same slot
    /// namespace used by Audio Units. The caller owns the descriptor context.
    @discardableResult
    func install(_ descriptor: ETExternalProcessor, instanceID: String) throws -> UInt8 {
        let index = try reserve(instanceID: instanceID)
        var descriptor = descriptor
        withUnsafePointer(to: &descriptor) {
            ETPipeline_SetExternalProcessorAt(UInt32(index), $0)
        }
        return index
    }

    func index(for instanceID: String) -> UInt8? { indices[instanceID] }

    func remove(instanceID: String) {
        guard let index = indices.removeValue(forKey: instanceID) else { return }
        ETPipeline_ClearExternalProcessorAt(UInt32(index))
        if let adapter = adapters.removeValue(forKey: instanceID) {
            retired.append(adapter)
        }
    }

    func clear() {
        ETPipeline_ClearExternalProcessor()
        retired.append(contentsOf: adapters.values)
        adapters.removeAll()
        indices.removeAll()
    }

    /// Audio engine is stopped, so no render callback can still hold an old
    /// context. Release render resources but keep instance-to-slot identity.
    func suspend() {
        ETPipeline_ClearExternalProcessor()
        adapters.removeAll()
        retired.removeAll()
    }

    fileprivate final class RenderInput {
        let planar: UnsafeMutablePointer<Float>
        let interleaved: UnsafeMutablePointer<Float>
        let maxFrames: Int
        let maxChannels: Int
        var channels = 0
        var frames = 0

        init(maxFrames: Int, maxChannels: Int) {
            self.maxFrames = maxFrames
            self.maxChannels = maxChannels
            planar = .allocate(capacity: maxFrames * maxChannels)
            interleaved = .allocate(capacity: maxFrames * maxChannels)
            planar.initialize(repeating: 0, count: maxFrames * maxChannels)
            interleaved.initialize(repeating: 0, count: maxFrames * maxChannels)
        }

        deinit {
            planar.deinitialize(count: maxFrames * maxChannels)
            planar.deallocate()
            interleaved.deinitialize(count: maxFrames * maxChannels)
            interleaved.deallocate()
        }

        func provide(frameCount: Int, inputData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
            guard frameCount <= frames else { return kAudioUnitErr_TooManyFramesToProcess }
            let buffers = UnsafeMutableAudioBufferListPointer(inputData)
            if buffers.count == 1, channels > 1 {
                buffers[0].mNumberChannels = UInt32(channels)
                buffers[0].mDataByteSize = UInt32(frameCount * channels * MemoryLayout<Float>.size)
                buffers[0].mData = UnsafeMutableRawPointer(interleaved)
                return noErr
            }
            guard buffers.count >= channels else { return kAudioUnitErr_FormatNotSupported }
            for channel in 0..<channels {
                buffers[channel].mNumberChannels = 1
                buffers[channel].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
                buffers[channel].mData = UnsafeMutableRawPointer(
                    planar.advanced(by: channel * maxFrames))
            }
            return noErr
        }
    }

    fileprivate final class Adapter {
        let unit: AUAudioUnit
        let render: AURenderBlock
        let sampleRate: Double
        let channels: Int
        let maxFrames: Int
        let input: RenderInput
        let output: UnsafeMutablePointer<Float>
        let outputList: UnsafeMutableAudioBufferListPointer
        let pullInput: AURenderPullInputBlock
        var descriptor = ETExternalProcessor()

        init(unit: AUAudioUnit, sampleRate: Double, channels: Int, maxFrames: Int) throws {
            guard channels > 0, channels <= 16,
                  let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                              channels: AVAudioChannelCount(channels)),
                  unit.inputBusses.count > 0,
                  unit.outputBusses.count > 0 else {
                throw BridgeError.unsupportedFormat(sampleRate, channels)
            }

            self.unit = unit
            self.sampleRate = sampleRate
            self.channels = channels
            self.maxFrames = maxFrames
            input = RenderInput(maxFrames: maxFrames, maxChannels: channels)
            output = .allocate(capacity: maxFrames * channels)
            output.initialize(repeating: 0, count: maxFrames * channels)
            outputList = AudioBufferList.allocate(maximumBuffers: channels)

            let renderInput = input
            pullInput = { _, _, frameCount, _, inputData in
                renderInput.provide(frameCount: Int(frameCount), inputData: inputData)
            }

            let au = unit
            au.maximumFramesToRender = AUAudioFrameCount(maxFrames)
            do {
                let inputBus = au.inputBusses[0]
                let outputBus = au.outputBusses[0]
                try inputBus.setFormat(format)
                try outputBus.setFormat(format)
                // AVAudioEngine normally enables buses when it connects nodes.
                // A direct AUAudioUnit host must do it explicitly; otherwise
                // renderBlock returns kAudioUnitErr_NoConnection every block.
                inputBus.isEnabled = true
                outputBus.isEnabled = true
                try au.allocateRenderResources()
            } catch {
                outputList.unsafeMutablePointer.deallocate()
                output.deinitialize(count: maxFrames * channels)
                output.deallocate()
                throw error
            }
            render = au.renderBlock

            descriptor.context = Unmanaged.passUnretained(self).toOpaque()
            descriptor.process = etaProcess
            descriptor.reset = etaReset
            descriptor.latency = etaLatency
            descriptor.tailTime = etaTailTime
            descriptor.maxFrames = UInt32(maxFrames)
            descriptor.maxChannels = UInt32(channels)
        }

        deinit {
            unit.deallocateRenderResources()
            output.deinitialize(count: maxFrames * channels)
            output.deallocate()
            outputList.unsafeMutablePointer.deallocate()
        }

        func process(_ planar: UnsafeMutablePointer<Float>, channelCount: Int,
                     frameCount: Int, timeSeconds: Double) -> Int32 {
            guard channelCount == channels, frameCount > 0, frameCount <= maxFrames else {
                return 0
            }

            input.channels = channelCount
            input.frames = frameCount
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    let value = planar[channel * frameCount + frame]
                    input.planar[channel * maxFrames + frame] = value
                    input.interleaved[frame * channelCount + channel] = value
                }
            }

            let buffers = outputList
            buffers.count = channelCount
            for channel in 0..<channelCount {
                buffers[channel].mNumberChannels = 1
                buffers[channel].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
                buffers[channel].mData = UnsafeMutableRawPointer(
                    output.advanced(by: channel * maxFrames))
            }

            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = timeSeconds * sampleRate
            timestamp.mFlags = .sampleTimeValid
            let status = render(&flags, &timestamp, AUAudioFrameCount(frameCount), 0,
                                outputList.unsafeMutablePointer, pullInput)
            // Preserve the input (safe bypass) but expose the actual AU error
            // to the host diagnostics instead of reporting a false success.
            guard status == noErr else { return status }

            let rendered = UnsafeMutableAudioBufferListPointer(outputList.unsafeMutablePointer)
            if rendered.count == 1, channelCount > 1,
               let samples = rendered[0].mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<frameCount {
                    for channel in 0..<channelCount {
                        planar[channel * frameCount + frame] = samples[frame * channelCount + channel]
                    }
                }
                return 0
            }
            guard rendered.count >= channelCount else { return 0 }
            for channel in 0..<channelCount {
                guard let samples = rendered[channel].mData?.assumingMemoryBound(to: Float.self) else {
                    return 0
                }
                planar.advanced(by: channel * frameCount).assign(from: samples, count: frameCount)
            }
            return 0
        }

        func reset() { unit.reset() }

        var latencySamples: UInt32 {
            UInt32(max(0, (unit.latency * sampleRate).rounded(.up)))
        }

        var tailTime: Double { max(0, unit.tailTime) }
    }
}

private let etaProcess: ETExternalProcessorProcess = { context, planar, channels,
                                                        frames, _, timeSeconds in
    guard let context, let planar else { return 0 }
    let adapter = Unmanaged<ETAUExternalBridge.Adapter>.fromOpaque(context).takeUnretainedValue()
    return adapter.process(planar, channelCount: Int(channels), frameCount: Int(frames),
                           timeSeconds: timeSeconds)
}

private let etaReset: ETExternalProcessorReset = { context in
    guard let context else { return }
    Unmanaged<ETAUExternalBridge.Adapter>.fromOpaque(context).takeUnretainedValue().reset()
}

private let etaLatency: ETExternalProcessorLatency = { context in
    guard let context else { return 0 }
    return Unmanaged<ETAUExternalBridge.Adapter>.fromOpaque(context)
        .takeUnretainedValue().latencySamples
}

private let etaTailTime: ETExternalProcessorTailTime = { context in
    guard let context else { return 0 }
    return Unmanaged<ETAUExternalBridge.Adapter>.fromOpaque(context)
        .takeUnretainedValue().tailTime
}
