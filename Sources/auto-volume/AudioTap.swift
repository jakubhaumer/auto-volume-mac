import AudioToolbox
import CoreAudio
import Foundation
import AutoVolumeCore

enum EngineError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    case message(String)

    var description: String {
        switch self {
        case let .coreAudio(what, status):
            return "\(what) failed (OSStatus \(status))"
        case let .message(m):
            return m
        }
    }
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
final class AudioTapEngine {
    private let config: LevelerConfig
    private let verbose: Bool

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "auto-volume.io", qos: .userInteractive)

    private var leveler: Leveler?
    private var scratchL = [Float]()
    private var scratchR = [Float]()
    private var outputName = ""

    // Diagnostics (written on the IO thread, read for display only).
    private var cbCount = 0
    private var dbgInBuffers = 0
    private var dbgInChannels = 0
    private var dbgInFrames = 0
    private var dbgRawPeak: Float = 0
    private var dbgInMs: Double = 0, dbgOutMs: Double = 0, dbgN: Double = 0
    private var dbgOutPeak: Float = 0

    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var statusTimer: DispatchSourceTimer?
    private var restartWork: DispatchWorkItem?

    init(config: LevelerConfig, verbose: Bool) {
        self.config = config
        self.verbose = verbose
    }

    // MARK: - Lifecycle

    func start() throws {
        try buildPipeline()
        installDefaultDeviceListener()
        if verbose { startStatusTimer() }
    }

    func stop() {
        statusTimer?.cancel()
        statusTimer = nil
        restartWork?.cancel()
        removeDefaultDeviceListener()
        tearDownPipeline()
    }

    // MARK: - Pipeline

    private func buildPipeline() throws {
        let outputID = try Self.defaultOutputDevice()
        let outputUID = try Self.deviceUID(outputID)
        outputName = (try? Self.deviceName(outputID)) ?? outputUID

        // 1. Global stereo tap that mutes the original audio.
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
            let lv = Leveler(sampleRate: rate, config: config)
            leveler = lv
            scratchL = [Float](repeating: 0, count: 16_384)
            scratchR = [Float](repeating: 0, count: 16_384)

            // 4. IO proc.
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
                [unowned self] _, inData, _, outData, _ in
                self.render(input: inData, output: outData)
            }, "AudioDeviceCreateIOProcIDWithBlock")
            try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")

            print("Leveling system audio -> \(outputName) @ \(Int(rate)) Hz"
                  + (config.bypass ? " [BYPASS]" : ""))
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

        cbCount += 1
        dbgInBuffers = inBuffers.count
        dbgInChannels = inBuffers.reduce(0) { $0 + Int($1.mNumberChannels) }

        // Output frame count from the first output buffer.
        guard let firstOut = outBuffers.first, firstOut.mNumberChannels > 0 else { return }
        let outFrames = Int(firstOut.mDataByteSize) / (MemoryLayout<Float>.size * Int(firstOut.mNumberChannels))

        // Gather input into planar stereo scratch.
        var inFrames = 0
        var channelIndex = 0
        scratchL.withUnsafeMutableBufferPointer { lp in
            scratchR.withUnsafeMutableBufferPointer { rp in
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
                dbgInFrames = inFrames
                var pk: Float = 0
                for f in 0..<min(inFrames, lp.count) { pk = max(pk, abs(lp[f]), abs(rp[f])) }
                dbgRawPeak = max(pk, dbgRawPeak * 0.5)
                if channelIndex == 1 { // mono tap: duplicate
                    for f in 0..<frames { rp[f] = lp[f] }
                }
                var inSum = 0.0
                for f in 0..<frames { inSum += Double(0.5 * (lp[f] + rp[f]) * 0.5 * (lp[f] + rp[f])) }
                if frames > 0 {
                    leveler.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: frames)
                }

                var outSum = 0.0
                var opk: Float = 0
                for f in 0..<frames {
                    let m = 0.5 * (lp[f] + rp[f]); outSum += Double(m * m)
                    opk = max(opk, abs(lp[f]), abs(rp[f]))
                }
                dbgInMs += inSum; dbgOutMs += outSum; dbgN += Double(frames)
                dbgOutPeak = max(dbgOutPeak, opk)

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
            guard let self else { return }
            print("Default output device changed; restarting…")
            self.tearDownPipeline()
            do { try self.buildPipeline() } catch {
                FileHandle.standardError.write(Data("Restart failed: \(error)\n".utf8))
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - Verbose status

    private func startStatusTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let lv = self?.leveler else { return }
            guard let self else { return }
            let n = max(self.dbgN, 1)
            let inDb = 10 * log10(max(self.dbgInMs / n, 1e-12))
            let outDb = 10 * log10(max(self.dbgOutMs / n, 1e-12))
            print(String(format: "METER in %6.1f dB  out %6.1f dB  out-peak %5.1f dBFS", inDb, outDb,
                         20 * log10(Double(max(self.dbgOutPeak, 1e-9)))))
            self.dbgInMs = 0; self.dbgOutMs = 0; self.dbgN = 0; self.dbgOutPeak = 0
            print(String(format: "level %6.1f dB   gain %+5.1f dB   | callbacks %d, in buffers %d, in channels %d, frames %d, raw peak %.5f",
                         lv.currentLevelDb, lv.currentGainDb, self.cbCount, self.dbgInBuffers,
                         self.dbgInChannels, self.dbgInFrames, self.dbgRawPeak))
        }
        timer.resume()
        statusTimer = timer
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
