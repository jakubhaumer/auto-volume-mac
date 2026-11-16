import AudioToolbox
import CoreAudio
import Foundation

public enum EngineError: Error, LocalizedError, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    case message(String)

    public var description: String {
        switch self {
        case let .coreAudio(what, status): return "\(what) failed (OSStatus \(status))"
        case let .message(m): return m
        }
    }

    public var errorDescription: String? { description }
}

private func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw EngineError.coreAudio(what, status) }
}

private func address(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

/// Captures all system audio with a Core Audio process tap (muting the original),
/// runs it through the `Leveler`, and plays the result on the default output device.
public final class AudioTapEngine {
    /// A snapshot of what the engine heard since the previous `readMetrics()` call.
    public struct Metrics {
        /// Loudness of what apps are playing, dBFS RMS (-120 = silence).
        public var inputDb: Float = -120
        /// Loudness after leveling, dBFS RMS.
        public var outputDb: Float = -120
        /// Effective gain applied (output minus input), dB.
        public var gainDb: Float = 0
        /// True once any non-zero audio sample has been received since start.
        public var heardAudio = false
        public var callbacks = 0
        public init() {}
    }

    public private(set) var isRunning = false
    public private(set) var outputDeviceName = ""
    /// Called on the main queue after the default output device changed and the pipeline restarted.
    public var onOutputDeviceChanged: ((String) -> Void)?
    /// Called on the main queue if an automatic restart failed.
    public var onError: ((Error) -> Void)?

    private var config: LevelerConfig

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "auto-volume.io", qos: .userInteractive)

    private var leveler: Leveler?
    private var scratchL = [Float]()
    private var scratchR = [Float]()

    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var restartWork: DispatchWorkItem?

    // Metering (written on the IO thread, read + reset by readMetrics()).
    private var cbCount = 0
    private var heardAudio = false
    private var accIn = 0.0, accOut = 0.0, accN = 0.0

    public init(config: LevelerConfig = LevelerConfig()) {
        self.config = config
    }

    // MARK: - Public API

    public func start() throws {
        guard !isRunning else { return }
        try buildPipeline()
        installDefaultDeviceListener()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        restartWork?.cancel()
        removeDefaultDeviceListener()
        tearDownPipeline()
        isRunning = false
    }

    /// Rebuilds the pipeline (e.g. after the Mac woke from sleep).
    public func restart() throws {
        guard isRunning else { return }
        tearDownPipeline()
        try buildPipeline()
    }

    /// Applies new settings immediately, without interrupting audio.
    public func updateConfig(_ newConfig: LevelerConfig) {
        config = newConfig
        leveler?.config = newConfig
    }

    public func readMetrics() -> Metrics {
        var m = Metrics()
        let n = accN
        if n > 0 {
            m.inputDb = Float(10 * log10(max(accIn / n, 1e-12)))
            m.outputDb = Float(10 * log10(max(accOut / n, 1e-12)))
            m.gainDb = m.inputDb > -75 ? m.outputDb - m.inputDb : 0
        }
        accIn = 0; accOut = 0; accN = 0
        m.heardAudio = heardAudio
        m.callbacks = cbCount
        return m
    }

    // MARK: - Pipeline

    private func buildPipeline() throws {
        let outputID = try Self.defaultOutputDevice()
        let outputUID = try Self.deviceUID(outputID)
        outputDeviceName = (try? Self.deviceName(outputID)) ?? outputUID
        cbCount = 0
        heardAudio = false
        accIn = 0; accOut = 0; accN = 0

        // 1. Global stereo tap that mutes the original audio (but never our own output).
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
        desc.name = "auto-volume tap"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .muted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "AudioHardwareCreateProcessTap")

        do {
            // 2. Private aggregate device: tap as input, default output as sub-device (and clock).
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "auto-volume",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID],
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: desc.uuid.uuidString,
                    ],
                ],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                      "AudioHardwareCreateAggregateDevice")

            // 3. Sample rate of the aggregate drives the DSP coefficients.
            let rate = try Self.nominalSampleRate(aggregateID)
            leveler = Leveler(sampleRate: rate, config: config)
            scratchL = [Float](repeating: 0, count: 16_384)
            scratchR = [Float](repeating: 0, count: 16_384)

            // 4. IO proc.
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
                [unowned self] _, inData, _, outData, _ in
                self.render(input: inData, output: outData)
            }, "AudioDeviceCreateIOProcIDWithBlock")
            try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
        } catch {
            tearDownPipeline()
            throw error
        }
    }

    private func tearDownPipeline() {
        if let proc = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID) // un-mutes the original audio
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        leveler = nil
    }

    // MARK: - Real-time render (no allocations, no locks)

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        guard let leveler else { return }
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outBuffers = UnsafeMutableAudioBufferListPointer(output)
        cbCount &+= 1

        guard let firstOut = outBuffers.first, firstOut.mNumberChannels > 0 else { return }
        let outFrames = Int(firstOut.mDataByteSize) / (MemoryLayout<Float>.size * Int(firstOut.mNumberChannels))

        var inFrames = 0
        var channelIndex = 0
        scratchL.withUnsafeMutableBufferPointer { lp in
            scratchR.withUnsafeMutableBufferPointer { rp in
                // Gather input into planar stereo scratch.
                for buf in inBuffers {
                    guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let nch = Int(buf.mNumberChannels)
                    guard nch > 0 else { continue }
                    let frames = min(Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * nch), lp.count)
                    inFrames = max(inFrames, frames)
                    for c in 0..<nch where channelIndex + c < 2 {
                        let dst = (channelIndex + c == 0) ? lp : rp
                        for f in 0..<frames { dst[f] = data[f * nch + c] }
                    }
                    channelIndex += nch
                }

                let frames = min(inFrames, outFrames, lp.count)
                if channelIndex == 1 { for f in 0..<frames { rp[f] = lp[f] } } // mono tap: duplicate

                var inSum = 0.0
                var rawPeak: Float = 0
                for f in 0..<frames {
                    let m = 0.5 * (lp[f] + rp[f])
                    inSum += Double(m * m)
                    rawPeak = max(rawPeak, abs(lp[f]), abs(rp[f]))
                }
                if rawPeak > 0 { heardAudio = true }

                if frames > 0 {
                    leveler.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: frames)
                }

                var outSum = 0.0
                for f in 0..<frames {
                    let m = 0.5 * (lp[f] + rp[f])
                    outSum += Double(m * m)
                }
                accIn += inSum; accOut += outSum; accN += Double(frames)

                // Scatter to output buffers: channel 0 -> L, 1 -> R, others silent.
                var outChannel = 0
                for buf in outBuffers {
                    guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let nch = Int(buf.mNumberChannels)
                    guard nch > 0 else { continue }
                    let bufFrames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * nch)
                    for c in 0..<nch {
                        let global = outChannel + c
                        for f in 0..<bufFrames {
                            data[f * nch + c] = (f < frames && global < 2) ? (global == 0 ? lp[f] : rp[f]) : 0
                        }
                    }
                    outChannel += nch
                }
            }
        }
    }

    // MARK: - Default output change handling

    private func installDefaultDeviceListener() {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRestart()
        }
        defaultDeviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListener else { return }
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        defaultDeviceListener = nil
    }

    /// Debounced rebuild when the user switches output device.
    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.tearDownPipeline()
            do {
                try self.buildPipeline()
                self.onOutputDeviceChanged?(self.outputDeviceName)
            } catch {
                self.onError?(error)
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - Core Audio helpers

    /// Core Audio process object(s) for this process, so our own output is never tapped/muted.
    static func ownProcessObjects() -> [AudioObjectID] {
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return (st == noErr && obj != kAudioObjectUnknown) ? [obj] : []
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id),
                  "get default output device")
        guard id != kAudioObjectUnknown else { throw EngineError.message("No default output device") }
        return id
    }

    static func deviceUID(_ id: AudioDeviceID) throws -> String {
        try stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ id: AudioDeviceID) throws -> String {
        try stringProperty(id, kAudioObjectPropertyName)
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value), "get string property")
        guard let s = value?.takeRetainedValue() else { throw EngineError.message("Empty string property") }
        return s as String
    }

    static func nominalSampleRate(_ id: AudioObjectID) throws -> Double {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate), "get sample rate")
        return rate > 0 ? rate : 48_000
    }
}
