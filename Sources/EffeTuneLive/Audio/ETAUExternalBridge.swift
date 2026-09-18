// ETAUExternalBridge.swift
// AUAudioUnit.renderBlock -> ETExternalProcessor bridge.

import AVFoundation
import AudioToolbox

/// Owns the realtime-safe AU adapter installed in the external processor slot.
/// The adapter is intentionally process-wide: the C pipeline callback is a
/// plain function pointer and must not capture Swift actor state.
final class ETAUExternalBridge {
    static let shared = ETAUExternalBridge()

    private var adapter: Adapter?

    private init() {}

    func install(_ unit: AVAudioUnit, sampleRate: Double = 48_000,
                 maxFrames: Int = 4096, maxChannels: Int = 16) {
        let next = Adapter(unit: unit, sampleRate: sampleRate,
                           maxFrames: maxFrames, maxChannels: maxChannels)
        adapter = next
        var descriptor = next.descriptor
        withUnsafePointer(to: &descriptor) { ptr in
            ETPipeline_SetExternalProcessor(ptr)
        }
    }

    func clear() {
        adapter = nil
        ETPipeline_ClearExternalProcessor()
    }

    private final class Adapter {
        let render: AUAudioUnitRenderBlock
        let sampleRate: Double
        let maxFrames: Int
        let maxChannels: Int
        let scratch: UnsafeMutablePointer<Float>

        var descriptor: ETExternalProcessor

        init(unit: AVAudioUnit, sampleRate: Double, maxFrames: Int, maxChannels: Int) {
            self.render = unit.auAudioUnit.renderBlock
            self.sampleRate = sampleRate
            self.maxFrames = maxFrames
            self.maxChannels = maxChannels
            self.scratch = .allocate(capacity: maxFrames * maxChannels)
            self.scratch.initialize(repeating: 0, count: maxFrames * maxChannels)
            self.descriptor = ETExternalProcessor()
            self.descriptor.context = Unmanaged.passUnretained(self).toOpaque()
            self.descriptor.process = etaProcess
            self.descriptor.maxFrames = UInt32(maxFrames)
            self.descriptor.maxChannels = UInt32(maxChannels)
        }

        deinit {
            scratch.deinitialize(count: maxFrames * maxChannels)
            scratch.deallocate()
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

            var outputBuffers = makeBufferList(channels: channels, frames: frames,
                                               base: scratch, stride: maxFrames)
            let status = withUnsafeMutablePointer(to: &outputBuffers) { output in
                render(&flags, &timestamp, AUAudioFrameCount(frames), 0, output, nil,
                       pullInput)
            }
            guard status == noErr else { return Int32(status) }

            for c in 0..<channels {
                planar.advanced(by: c * frames)
                    .assign(from: scratch.advanced(by: c * maxFrames), count: frames)
            }
            return 0
        }

        private func makeBufferList(channels: Int, frames: Int,
                                    base: UnsafeMutablePointer<Float>, stride: Int) -> AudioBufferList {
            var list = AudioBufferList()
            list.mNumberBuffers = UInt32(channels)
            // AudioBufferList.audioBuffer is a one-element tuple in Swift;
            // the AU callback accepts the first buffer for stereo and uses the
            // supplied channel count. The current AU path is stereo-first.
            list.mBuffers.mNumberChannels = UInt32(channels)
            list.mBuffers.mDataByteSize = UInt32(frames * MemoryLayout<Float>.size * channels)
            list.mBuffers.mData = UnsafeMutableRawPointer(base)
            return list
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
