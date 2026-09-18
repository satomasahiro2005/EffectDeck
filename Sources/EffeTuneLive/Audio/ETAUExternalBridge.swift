// ETAUExternalBridge.swift
// AUAudioUnit.renderBlock -> ETExternalProcessor bridge.

import AVFoundation
import AudioToolbox

/// Owns the realtime-safe AU adapter installed in the external processor slot.
/// The adapter is intentionally process-wide: the C pipeline callback is a
/// plain function pointer and must not capture Swift actor state.
final class ETAUExternalBridge {
    static let shared = ETAUExternalBridge()

    private var adapters: [UInt8: Adapter] = [:]
    private var indices: [String: UInt8] = [:]

    private init() {}

    func index(for id: String) -> UInt8 {
        if let value = indices[id] { return value }
        let used = Set(indices.values)
        let value = (0..<UInt8(8)).first { !used.contains($0) } ?? 0
        indices[id] = value
        return value
    }

    func install(_ unit: AVAudioUnit, index: UInt8 = 0, sampleRate: Double = 48_000,
                 maxFrames: Int = 4096, maxChannels: Int = 16) {
        let next = Adapter(unit: unit, sampleRate: sampleRate,
                           maxFrames: maxFrames, maxChannels: maxChannels)
        adapters[index] = next
        var descriptor = next.descriptor
        withUnsafePointer(to: &descriptor) { ptr in
            ETPipeline_SetExternalProcessorAt(UInt32(index), ptr)
        }
    }

    func clear() {
        adapters.removeAll()
        ETPipeline_ClearExternalProcessor()
    }

    private final class Adapter {
        let render: AUAudioUnitRenderBlock
        let sampleRate: Double
        let maxFrames: Int
        let maxChannels: Int
        let scratch: UnsafeMutablePointer<Float>
        let outputList: UnsafeMutablePointer<AudioBufferList>

        var descriptor: ETExternalProcessor

        init(unit: AVAudioUnit, sampleRate: Double, maxFrames: Int, maxChannels: Int) {
            self.render = unit.auAudioUnit.renderBlock
            self.sampleRate = sampleRate
            self.maxFrames = maxFrames
            self.maxChannels = maxChannels
            self.scratch = .allocate(capacity: maxFrames * maxChannels)
            self.scratch.initialize(repeating: 0, count: maxFrames * maxChannels)
            self.outputList = AudioBufferList.allocate(maximumBuffers: maxChannels)
            self.descriptor = ETExternalProcessor()
            self.descriptor.context = Unmanaged.passUnretained(self).toOpaque()
            self.descriptor.process = etaProcess
            self.descriptor.maxFrames = UInt32(maxFrames)
            self.descriptor.maxChannels = UInt32(maxChannels)
        }

        deinit {
            scratch.deinitialize(count: maxFrames * maxChannels)
            scratch.deallocate()
            outputList.deallocate()
        }

        func process(_ planar: UnsafeMutablePointer<Float>, channels: Int,
                     frames: Int, sampleTime: Double) -> Int32 {
            guard channels > 0, channels <= maxChannels,
                  frames > 0, frames <= maxFrames else { return -2 }

            // Copy into an interleaved-by-buffer AudioBufferList layout owned
            // by this adapter. No allocation occurs on the render thread.
            for c in 0..<channels {
                scratch.advanced(by: c * maxFrames)
                    .assign(from: planar.advanced(by: c * frames), count: frames)
            }

            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = sampleTime * sampleRate

            let buffers = UnsafeMutableAudioBufferListPointer(outputList)
            buffers.count = channels
            for c in 0..<channels {
                buffers[c].mNumberChannels = 1
                buffers[c].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
                buffers[c].mData = UnsafeMutableRawPointer(scratch.advanced(by: c * maxFrames))
            }
            let status = render(&flags, &timestamp, AUAudioFrameCount(frames), 0,
                                outputList, nil, pullInput)
            guard status == noErr else { return Int32(status) }

            for c in 0..<channels {
                planar.advanced(by: c * frames)
                    .assign(from: scratch.advanced(by: c * maxFrames), count: frames)
            }
            return 0
        }

    }
}

private let etaProcess: ETExternalProcessorProcess = { context, planar, channels,
                                                        frames, _, sampleTime in
    guard let context, let planar else { return -1 }
    let adapter = Unmanaged<ETAUExternalBridge.Adapter>.fromOpaque(context).takeUnretainedValue()
    return adapter.process(planar, channels: Int(channels), frames: Int(frames),
                           sampleTime: sampleTime)
}

private let pullInput: AURenderPullInputBlock = { _, _, _, _, _ in noErr }
