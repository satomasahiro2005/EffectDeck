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
    // Render callbacks are C function pointers. Keep replaced adapters alive
    // for the lifetime of the host rather than risking a use-after-free on a
    // block that was already admitted by the audio thread.
    private var retired: [Adapter] = []

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
        guard let next = Adapter(unit: unit, sampleRate: sampleRate,
                                 maxFrames: maxFrames, maxChannels: maxChannels) else {
            return
        }
        if let old = adapters.updateValue(next, forKey: index) { retired.append(old) }
        var descriptor = next.descriptor
        withUnsafePointer(to: &descriptor) { ptr in
            ETPipeline_SetExternalProcessorAt(UInt32(index), ptr)
        }
    }

    func clear() {
        // Drop the C descriptors first. The render thread may still be
        // finishing the current block, so keep Adapter objects alive until
        // the registry has been detached from the pipeline.
        ETPipeline_ClearExternalProcessor()
        retired.append(contentsOf: adapters.values)
        adapters.removeAll()
    }

    fileprivate final class Adapter {
        let unit: AVAudioUnit
        let render: AURenderBlock
        let sampleRate: Double
        let maxFrames: Int
        let maxChannels: Int
        let scratch: UnsafeMutablePointer<Float>
        let outputList: UnsafeMutableAudioBufferListPointer
        var activeChannels = 0
        var activeFrames = 0
        var pullInput: AURenderPullInputBlock!

        var descriptor: ETExternalProcessor

        init?(unit: AVAudioUnit, sampleRate: Double, maxFrames: Int, maxChannels: Int) {
            self.unit = unit
            self.render = unit.auAudioUnit.renderBlock
            self.sampleRate = sampleRate
            self.maxFrames = maxFrames
            self.maxChannels = maxChannels
            self.scratch = .allocate(capacity: maxFrames * maxChannels)
            self.scratch.initialize(repeating: 0, count: maxFrames * maxChannels)
            self.outputList = AudioBufferList.allocate(maximumBuffers: maxChannels)
            let channelCount = AVAudioChannelCount(min(maxChannels, 2))
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                              channels: channelCount),
                  unit.auAudioUnit.inputBusses.count > 0,
                  unit.auAudioUnit.outputBusses.count > 0 else {
                self.outputList.unsafeMutablePointer.deallocate()
                self.scratch.deinitialize(count: maxFrames * maxChannels)
                self.scratch.deallocate()
                return nil
            }
            do {
                try unit.auAudioUnit.inputBusses[0].setFormat(format)
                try unit.auAudioUnit.outputBusses[0].setFormat(format)
                try unit.auAudioUnit.allocateRenderResources()
            } catch {
                self.outputList.unsafeMutablePointer.deallocate()
                self.scratch.deinitialize(count: maxFrames * maxChannels)
                self.scratch.deallocate()
                return nil
            }
            self.descriptor = ETExternalProcessor()
            self.descriptor.context = Unmanaged.passUnretained(self).toOpaque()
            self.descriptor.process = etaProcess
            self.descriptor.maxFrames = UInt32(maxFrames)
            self.descriptor.maxChannels = UInt32(maxChannels)
            self.pullInput = { [weak self] _, _, frameCount, _, inputData in
                guard let self, Int(frameCount) <= self.maxFrames else { return -1 }
                let requested = min(self.activeChannels,
                                    Int(inputData.pointee.mNumberBuffers))
                let buffers = UnsafeMutableAudioBufferListPointer(inputData)
                for c in 0..<requested {
                    let source = self.scratch.advanced(by: c * self.maxFrames)
                    let destination = buffers[c].mData?.assumingMemoryBound(to: Float.self)
                    guard let destination else { return -1 }
                    destination.assign(from: source, count: Int(frameCount))
                    buffers[c].mDataByteSize = UInt32(Int(frameCount) * MemoryLayout<Float>.size)
                }
                return noErr
            }
        }

        deinit {
            unit.auAudioUnit.deallocateRenderResources()
            scratch.deinitialize(count: maxFrames * maxChannels)
            scratch.deallocate()
            outputList.unsafeMutablePointer.deallocate()
        }

        func process(_ planar: UnsafeMutablePointer<Float>, channels: Int,
                     frames: Int, sampleTime: Double) -> Int32 {
            guard channels > 0, channels <= maxChannels,
                  frames > 0, frames <= maxFrames else { return -2 }
            activeChannels = channels
            activeFrames = frames

            // Copy into an interleaved-by-buffer AudioBufferList layout owned
            // by this adapter. No allocation occurs on the render thread.
            for c in 0..<channels {
                scratch.advanced(by: c * maxFrames)
                    .assign(from: planar.advanced(by: c * frames), count: frames)
            }

            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = sampleTime * sampleRate

            let buffers = outputList
            buffers.count = channels
            for c in 0..<channels {
                buffers[c].mNumberChannels = 1
                buffers[c].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
                buffers[c].mData = UnsafeMutableRawPointer(scratch.advanced(by: c * maxFrames))
            }
            let status = render(&flags, &timestamp, AUAudioFrameCount(frames), 0,
                                outputList.unsafeMutablePointer, pullInput)
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
