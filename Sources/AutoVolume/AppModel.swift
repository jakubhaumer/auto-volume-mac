import SwiftUI
import ServiceManagement
import AutoVolumeCore

/// User-facing presets. Each maps to a set of leveler parameters.
enum LevelMode: String, CaseIterable, Identifiable {
    case gentle, balanced, strong, night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gentle: return "Gentle"
        case .balanced: return "Balanced"
        case .strong: return "Strong"
        case .night: return "Night"
        }
    }

    var blurb: String {
        switch self {
        case .gentle: return "Light touch. Keeps most of the natural dynamics."
        case .balanced: return "Recommended. Clear dialogue, calmer loud scenes."
        case .strong: return "Very even volume. Best for noisy rooms or travel."
        case .night: return "Quietens loud scenes and explosions. Good for late hours."
        }
    }

    var symbol: String {
        switch self {
        case .gentle: return "leaf"
        case .balanced: return "slider.horizontal.3"
        case .strong: return "bolt"
        case .night: return "moon.stars"
        }
    }

    var config: LevelerConfig {
        var c = LevelerConfig()
        switch self {
        case .gentle:
            c.bandDb = 11; c.maxBoostDb = 12; c.maxCutDb = 14; c.ratio = 2.5; c.compressorHeadroomDb = 18
        case .balanced:
            break
        case .strong:
            c.targetDb = -21; c.bandDb = 6; c.maxBoostDb = 24; c.maxCutDb = 24; c.ratio = 3.5
            c.compressorHeadroomDb = 12
        case .night:
            c.targetDb = -28; c.bandDb = 7; c.maxBoostDb = 18; c.maxCutDb = 28; c.ratio = 4
            c.compressorHeadroomDb = 8; c.ceilingDb = -3
        }
        return c
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let historyLength = 100 // samples (~30 s)

    @Published private(set) var isOn: Bool
    @Published private(set) var mode: LevelMode
    @Published private(set) var showGainInMenuBar: Bool
    @Published private(set) var launchAtLogin = false

    @Published private(set) var inputDb: Float = -90
    @Published private(set) var outputDb: Float = -90
    @Published private(set) var gainDb: Float = 0
    @Published private(set) var inHistory: [Float] = []
    @Published private(set) var outHistory: [Float] = []
    @Published private(set) var deviceName = ""
    @Published private(set) var errorText: String?
    @Published private(set) var noAudioWarning = false

    /// Called after every metrics tick so the menu bar item can refresh.
    var onTick: (() -> Void)?

    private var engine: AudioTapEngine?
    private var timer: Timer?
    private var tickCount = 0
    private var runningSeconds = 0.0
    private let defaults = UserDefaults.standard

    var isSilent: Bool { inputDb < -70 }

    init() {
        isOn = defaults.object(forKey: "isOn") as? Bool ?? true
        mode = LevelMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .balanced
        showGainInMenuBar = defaults.object(forKey: "showGain") as? Bool ?? true
        refreshLoginState()
    }

    /// Demo state used for design snapshots.
    static func demo() -> AppModel {
        let m = AppModel()
        m.isOn = true
        m.deviceName = "MacBook Pro Speakers"
        m.inputDb = -41; m.outputDb = -23; m.gainDb = 17.6
        var i: [Float] = [], o: [Float] = []
        for k in 0..<historyLength {
            let t = Float(k) / Float(historyLength - 1)
            let scene: Float = t < 0.35 ? -42 : (t < 0.7 ? -18 : -36)
            let wob = 4 * sinf(t * 38) + 2.5 * sinf(t * 91)
            i.append(scene + wob)
            let target: Float = -23 + 0.35 * wob
            let settle: Float = t < 0.35 ? 0 : (t < 0.7 ? max(0, 1 - (t - 0.35) * 14) * 9 : max(0, 1 - (t - 0.7) * 6) * -12)
            o.append(target + settle)
        }
        m.inHistory = i; m.outHistory = o
        return m
    }

    // MARK: - Controls

    func setOn(_ on: Bool) {
        isOn = on
        defaults.set(on, forKey: "isOn")
        on ? start() : stop()
        onTick?()
    }

    func setMode(_ newMode: LevelMode) {
        mode = newMode
        defaults.set(newMode.rawValue, forKey: "mode")
        engine?.updateConfig(newMode.config)
    }

    func setShowGain(_ show: Bool) {
        showGainInMenuBar = show
        defaults.set(show, forKey: "showGain")
        onTick?()
    }

    func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorText = "Couldn’t change the login setting. Move the app to Applications first."
        }
        refreshLoginState()
    }

    func refreshLoginState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Lifecycle

    func startIfNeeded() {
        if isOn { start() }
    }

    func shutdown() {
        stop()
    }

    /// Rebuilds the audio pipeline, e.g. after waking from sleep.
    func restartIfOn() {
        guard isOn, let engine else { return }
        do { try engine.restart(); errorText = nil } catch { errorText = Self.friendly(error) }
    }

    private func start() {
        stop()
        let e = AudioTapEngine(config: mode.config)
        e.onOutputDeviceChanged = { [weak self] name in
            self?.deviceName = name
            self?.errorText = nil
        }
        e.onError = { [weak self] error in self?.errorText = Self.friendly(error) }
        do {
            try e.start()
            engine = e
            deviceName = e.outputDeviceName
            errorText = nil
            runningSeconds = 0
            noAudioWarning = false
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } catch {
            errorText = Self.friendly(error)
            engine = nil
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        engine?.stop()
        engine = nil
        inputDb = -90; outputDb = -90; gainDb = 0
        inHistory = []; outHistory = []
        noAudioWarning = false
    }

    private func tick() {
        guard let engine else { return }
        let m = engine.readMetrics()
        runningSeconds += 0.1
        tickCount += 1

        let active = m.inputDb > -75
        inputDb += ((active ? m.inputDb : -90) - inputDb) * 0.4
        outputDb += ((active ? m.outputDb : -90) - outputDb) * 0.4
        if active { gainDb += (m.gainDb - gainDb) * 0.12 }

        if tickCount % 3 == 0 {
            inHistory.append(inputDb)
            outHistory.append(outputDb)
            if inHistory.count > Self.historyLength {
                inHistory.removeFirst(inHistory.count - Self.historyLength)
                outHistory.removeFirst(outHistory.count - Self.historyLength)
            }
        }
        noAudioWarning = runningSeconds > 6 && !m.heardAudio
        onTick?()
    }

    private static func friendly(_ error: Error) -> String {
        "Couldn’t start leveling (\(error.localizedDescription)). Check System Settings → Privacy & Security → Screen & System Audio Recording."
    }
}
