import Foundation

/// Tunable parameters for the leveler. All levels are in dBFS / dB.
struct LegacyConfig {
    /// Loudness (RMS, dBFS) the leveler steers the signal toward.
    var targetDb: Float = -23
    /// Maximum amount of gain added to quiet passages.
    var maxBoostDb: Float = 18
    /// Maximum amount of gain removed from loud passages.
    var maxCutDb: Float = 20
    /// Below this short-term level the signal is treated as silence and gain is held (not boosted).
    var gateDb: Float = -55
    /// Compressor ratio applied to peaks above `targetDb + compressorHeadroomDb`.
    var ratio: Float = 3
    /// How far above the target the fast compressor starts to act.
    var compressorHeadroomDb: Float = 16
    /// Limiter ceiling.
    var ceilingDb: Float = -1
    /// Half-width of the "natural dynamics" zone: while the loudness is within this many dB of
    /// the target the gain only drifts slowly, so normal speech emphasis passes through untouched.
    /// A larger deviation is treated as a scene change and corrected quickly until within ~2.5 dB.
    var bandDb: Float = 9
    /// When true the signal passes through untouched (still delayed by the lookahead).
    var bypass: Bool = false

    init() {}
}

/// Stereo, allocation-free loudness leveler: slow AGC -> fast compressor -> lookahead limiter.
///
/// Call `process` from a single (audio) thread. The read-only properties `currentGainDb`
/// and `currentLevelDb` are safe to poll from another thread for display purposes.
final class LegacyLeveler {
    var config: LegacyConfig
    private(set) var currentGainDb: Float = 0
    private(set) var currentLevelDb: Float = -120

    private let sampleRate: Float

    // Detector (slow RMS of a high-passed mono mix).
    private var hpState: Float = 0
    private var hpPrevIn: Float = 0
    private let hpCoef: Float
    private var meanSquare: Float = 0
    private let msCoef: Float
    // Presence detection: a fast detector tells "someone is speaking" from "a pause".
    private var fastSquare: Float = 0
    private let fastCoef: Float
    private var quietSamples = 0
    private let holdSamples: Int

    // AGC gain (linear-in-dB state, smoothed).
    private var agcGainDb: Float = 0
    private let agcAttackCoef: Float      // fast, used for the part of the error outside the band
    private let agcReleaseCoef: Float
    private let agcSlowCoef: Float        // slow drift used while inside the band
    private var sceneChange = false       // true while correcting a big loudness jump quickly

    // Compressor envelope follower on the post-AGC peak.
    private var compEnv: Float = 0
    private let compAttackCoef: Float
    private let compReleaseCoef: Float
    private let kneeDb: Float = 6

    // Limiter.
    private let lookahead: Int
    private var delayL: [Float]
    private var delayR: [Float]
    private var peakRing: [Float]
    private var ringPos = 0
    private var limiterGain: Float = 1
    private let limiterAttackCoef: Float
    private let limiterReleaseCoef: Float

    init(sampleRate: Double, config: LegacyConfig = LegacyConfig()) {
        let sr = Float(sampleRate)
        self.sampleRate = sr
        self.config = config

        func coef(_ seconds: Float) -> Float { exp(-1 / (seconds * sr)) }

        hpCoef = exp(-2 * .pi * 80 / sr)   // ~80 Hz one-pole high-pass
        msCoef = coef(0.6)                 // 600 ms RMS window
        fastCoef = coef(0.04)              // 40 ms presence detector
        holdSamples = Int(2.5 * sr)        // pauses shorter than this never change the gain
        agcAttackCoef = coef(0.2)          // big loud jump: reduce fast
        agcReleaseCoef = coef(0.75)        // gain increase: moderately slow
        agcSlowCoef = coef(4.0)
        compAttackCoef = coef(0.008)
        compReleaseCoef = coef(0.25)

        lookahead = max(1, Int(0.005 * sr)) // 5 ms
        delayL = [Float](repeating: 0, count: lookahead)
        delayR = [Float](repeating: 0, count: lookahead)
        peakRing = [Float](repeating: 0, count: lookahead)
        limiterAttackCoef = exp(-1 / (Float(lookahead) / 3))
        limiterReleaseCoef = coef(0.08)
    }

    /// Latency introduced by the limiter lookahead, in frames.
    var latencyFrames: Int { lookahead }

    @inline(__always) private func db(_ x: Float) -> Float { 20 * log10f(max(x, 1e-9)) }
    @inline(__always) private func lin(_ db: Float) -> Float { powf(10, db / 20) }

    /// Processes `frames` samples of planar stereo audio in place.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let cfg = config
        let targetDb = cfg.targetDb
        let compThreshold = targetDb + cfg.compressorHeadroomDb
        let slope = 1 - 1 / max(cfg.ratio, 1)
        let ceiling = lin(cfg.ceilingDb)

        for n in 0..<frames {
            let inL = left[n]
            let inR = right[n]

            var l = inL
            var r = inR

            if !cfg.bypass {
                // --- Detector: high-passed mono mix -> slow mean square.
                let mono = 0.5 * (inL + inR)
                let hp = hpCoef * (hpState + mono - hpPrevIn)
                hpState = hp
                hpPrevIn = mono
                fastSquare = fastCoef * fastSquare + (1 - fastCoef) * (hp * hp)
                let fastDb = 10 * log10f(max(fastSquare, 1e-12))
                let slowDb = 10 * log10f(max(meanSquare, 1e-12))

                // Presence: signal must be above the gate and not far below what we have been tracking.
                // During a pause (or room tone between phrases) everything is frozen, so the gain
                // cannot creep up and make the next phrase start too loud. After a long quiet spell
                // (a genuine scene change) tracking resumes.
                let present = fastDb > max(cfg.gateDb, slowDb - 15)
                quietSamples = present ? 0 : min(quietSamples + 1, holdSamples + 1)
                let tracking = present || quietSamples > holdSamples

                var levelDb = slowDb
                if tracking {
                    meanSquare = msCoef * meanSquare + (1 - msCoef) * (hp * hp)
                    levelDb = 10 * log10f(max(meanSquare, 1e-12))
                }
                currentLevelDb = levelDb

                // --- AGC: steer toward target; hold when paused or below the gate.
                if tracking && levelDb > cfg.gateDb {
                    let desired = min(cfg.maxBoostDb, max(-cfg.maxCutDb, targetDb - levelDb))
                    let err = desired - agcGainDb
                    // Small deviations drift slowly (keeps speech emphasis); a big jump switches to
                    // fast correction until we are close to the target again.
                    if !sceneChange && abs(err) > cfg.bandDb { sceneChange = true }
                    else if sceneChange && abs(err) < 2.5 { sceneChange = false }
                    let c = sceneChange ? (err < 0 ? agcAttackCoef : agcReleaseCoef) : agcSlowCoef
                    agcGainDb += (1 - c) * err
                }
                currentGainDb = agcGainDb
                let agcGain = lin(agcGainDb)
                l *= agcGain
                r *= agcGain

                // --- Fast compressor on post-AGC peak (soft knee).
                let peak = max(abs(l), abs(r))
                let ec = peak > compEnv ? compAttackCoef : compReleaseCoef
                compEnv = ec * compEnv + (1 - ec) * peak
                let envDb = db(compEnv)
                let over = envDb - compThreshold
                var reductionDb: Float = 0
                if over > kneeDb / 2 {
                    reductionDb = over * slope
                } else if over > -kneeDb / 2 {
                    let x = over + kneeDb / 2
                    reductionDb = slope * x * x / (2 * kneeDb)
                }
                if reductionDb > 0 {
                    let g = lin(-reductionDb)
                    l *= g
                    r *= g
                }
            }

            // --- Lookahead limiter: delay audio, track peak over the window.
            let slot = ringPos
            let delayedL = delayL[slot]
            let delayedR = delayR[slot]
            delayL[slot] = l
            delayR[slot] = r
            peakRing[slot] = max(abs(l), abs(r))
            ringPos = slot + 1 == lookahead ? 0 : slot + 1

            var windowPeak: Float = 0
            for p in peakRing where p > windowPeak { windowPeak = p }
            let needed: Float = windowPeak > ceiling ? ceiling / windowPeak : 1
            let lc = needed < limiterGain ? limiterAttackCoef : limiterReleaseCoef
            limiterGain = lc * limiterGain + (1 - lc) * needed

            // Hard safety clamp (final guard against any residual overshoot).
            left[n] = min(0.999, max(-0.999, delayedL * limiterGain))
            right[n] = min(0.999, max(-0.999, delayedR * limiterGain))
        }
    }
}
