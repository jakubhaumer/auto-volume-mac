import Foundation

/// Tunable parameters. Levels are K-weighted loudness in LUFS (ITU-R BS.1770), gains in dB.
///
/// The defaults and the structure are documented, with sources, in docs/RESEARCH.md.
public struct LevelerConfig {
    /// Loudness the leveler steers toward.
    public var targetLufs: Double = -19
    /// Half-width of the transparent zone: programme loudness within ±nullBandDb of the target is
    /// left untouched (EBU R 128 s4 / Tech 3343: leave the mix alone while loudness-to-dialogue
    /// differences are small).
    public var nullBandDb: Double = 1
    /// Slope outside the transparent zone, as an input:output ratio (1 = off, large = full leveling).
    public var boostRatio: Double = 30
    public var cutRatio: Double = 30
    /// Gain limits of the slow loop.
    public var maxBoostDb: Double = 18
    public var maxCutDb: Double = 20
    /// Fast guard: the gain may never exceed what the static curve would give for a signal that is this
    /// many dB quieter than the current short-term loudness. It retracts boost the instant a loud event
    /// starts, yet stays inactive for ordinary speech crest and emphasis.
    public var guardSlackDb: Double = 16
    /// True-peak ceiling of the output limiter, dBTP.
    public var ceilingDb: Double = -2
    /// Below this level the signal counts as silence/room tone; gain is frozen so it is never boosted
    /// (the broadcast "silence gate": Orban 464A manual - prevents noise rush-up, pumping, breathing).
    public var gateLufs: Double = -50
    /// Momentary guard: when output loudness (150 ms window) would exceed target + this margin, the excess
    /// is cut quickly (ratio = cutRatio). Catches sustained loud events without touching speech emphasis.
    public var momentaryMarginDb: Double = 10
    /// Time constant of the program-loudness estimate (BS.1770 Momentary = 0.4 s, Short-term = 3 s).
    public var levelWindowS: Double = 2.0
    /// Error-dependent gain speed: tau = tau0 / (1 + (|error| / adaptBandDb)^2). Small errors are corrected
    /// slowly (speech emphasis and normal dynamics survive), large ones quickly (scene changes).
    public var adaptBandDb: Double = 8
    public var riseTau0S: Double = 4
    public var fallTau0S: Double = 2.5
    /// Pass-through (same delay, no processing) for A/B comparison.
    public var bypass: Bool = false

    public init() {}
}

/// Stereo loudness leveler with a slow loop (program level), a fast protector (sudden loud events)
/// and a true-peak lookahead limiter.
///
/// Call `process` from one audio thread only. `currentGainDb`, `currentLevelLufs` and
/// `protectorGainDb` are for display and may be polled from another thread.
public final class Leveler {
    public var config: LevelerConfig
    public private(set) var currentGainDb: Float = 0
    public private(set) var currentLevelLufs: Float = -120
    public private(set) var protectorGainDb: Float = 0

    private let sr: Double

    // MARK: Fixed design constants (see docs/RESEARCH.md for the evidence behind each)
    private let block = 64                          // control-rate block (~1.3 ms)
    private let presenceMarginDb = 15.9             // ITU-T P.56 active-speech threshold margin
    private let presenceHangoverS = 0.2             // ITU-T P.56 hangover
    private let holdS = 2.0                         // pauses shorter than this never move the gain
    private let maxRiseDbPerS = 6.0                 // WebRTC AGC2 default gain-change limit
    private let maxFallDbPerS = 15.0
    private let protectorRecoveryS = 0.1            // Moore/Glasberg/Stone fast-component recovery 80-150 ms
    private let limiterReleaseS = 0.15
    private let limiterLookaheadS = 0.010
    private let gainLookaheadS = 0.005

    // MARK: Detection state (K-weighted, on the undelayed signal)
    private var kwL: KWeighting, kwR: KWeighting
    private var envP = 0.0          // 30 ms presence envelope (P.56)
    private var fastP = 0.0         // fast loudness (boost guard)
    private var momP = 0.0          // momentary loudness (output-referred cut guard)
    private let aMom: Double
    private var slowP = 0.0         // active-program loudness
    private let aEnv: Double, aFastRise: Double, aFastFall: Double
    private var aSlow: Double, aSlowAcquire: Double
    private var sRise: Double, sFall: Double

    private var tracking = false
    private var acquiring = true
    private var acquireTime = 0.0
    private var quietTime = 0.0
    private var slowValid = false

    // MARK: Gain state
    private var gSlow = 0.0         // dB
    private var gFast = 0.0         // dB (<= 0)
    private var gCur = 1.0, gStep = 0.0
    private var blockPos = 0

    // MARK: Gain-anticipation delay
    private var gdL: [Float], gdR: [Float]
    private var gdPos = 0

    // MARK: Limiter
    private let lookahead: Int
    private var limL: [Float], limR: [Float]
    private var limPos = 0
    private var truePeak: TruePeak
    private var dqVal: [Float], dqIdx: [Int]
    private var dqHead = 0, dqCount = 0
    private var sampleIndex = 0
    private var msRing: [Float]
    private var msSum: Double
    private var msPos = 0
    private var limGain = 1.0
    private let relCoef: Double

    public init(sampleRate: Double, config: LevelerConfig = LevelerConfig()) {
        sr = sampleRate
        self.config = config
        kwL = KWeighting(sampleRate: sampleRate)
        kwR = KWeighting(sampleRate: sampleRate)

        func a(_ seconds: Double) -> Double { 1 - exp(-1 / (seconds * sampleRate)) }
        aEnv = a(0.030)                  // P.56 envelope time constant
        aMom = a(0.150)
        aFastRise = a(0.010)
        aFastFall = a(0.100)
        aSlow = a(config.levelWindowS)  // symmetric: between BS.1770 Momentary (0.4 s) and Short-term (3 s)
        aSlowAcquire = a(0.3)
        sRise = aSlow; sFall = aSlow

        let gd = max(1, Int(gainLookaheadS * sampleRate))
        gdL = [Float](repeating: 0, count: gd)
        gdR = [Float](repeating: 0, count: gd)

        lookahead = max(2, Int(limiterLookaheadS * sampleRate))
        limL = [Float](repeating: 0, count: lookahead)
        limR = [Float](repeating: 0, count: lookahead)
        truePeak = TruePeak(sampleRate: sampleRate)
        dqVal = [Float](repeating: 1, count: lookahead + 2)
        dqIdx = [Int](repeating: 0, count: lookahead + 2)
        msRing = [Float](repeating: 1, count: lookahead)
        msSum = Double(lookahead)
        relCoef = exp(-1 / (limiterReleaseS * sampleRate))
    }

    /// Total added delay in frames.
    public var latencyFrames: Int { gdL.count + lookahead }

    @inline(__always) private func lin(_ db: Double) -> Double { pow(10, db / 20) }

    /// Static gain curve: unity inside the transparent zone, ratio-controlled boost below / cut above.
    /// With `softFloor`, the allowed boost fades from 0 at the silence gate to full 10 dB above it, so a noise
    /// floor near the gate is never boosted hard (no hiss rush-up).
    @inline(__always) private func curve(_ levelLufs: Double, _ cfg: LevelerConfig, softFloor: Bool) -> Double {
        let d = levelLufs - cfg.targetLufs
        var g = 0.0
        if d > cfg.nullBandDb { g = -(d - cfg.nullBandDb) * (1 - 1 / max(cfg.cutRatio, 1)) }
        else if d < -cfg.nullBandDb { g = (-d - cfg.nullBandDb) * (1 - 1 / max(cfg.boostRatio, 1)) }
        var maxBoost = cfg.maxBoostDb
        if softFloor {
            let f = min(1, max(0, (levelLufs - cfg.gateLufs) / 10))
            maxBoost *= f * f * (3 - 2 * f)          // smoothstep
        }
        return min(maxBoost, max(-cfg.maxCutDb, g))
    }

    /// Processes `frames` samples of planar stereo audio in place.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let cfg = config
        let ceiling = lin(cfg.ceilingDb)
        let bypass = cfg.bypass
        let gdLen = gdL.count

        for n in 0..<frames {
            let xl = Double(left[n]), xr = Double(right[n])

            // ---- Detection on the undelayed signal.
            let kl = kwL.process(xl), kr = kwR.process(xr)
            let p = kl * kl + kr * kr
            envP += (p - envP) * aEnv
            fastP += (p - fastP) * (p > fastP ? aFastRise : aFastFall)
            momP += (p - momP) * aMom
            if tracking { slowP += (p - slowP) * (p > slowP ? sRise : sFall) }

            blockPos += 1
            if blockPos == block {
                blockPos = 0
                control(cfg)
            }

            // ---- Gain stage on a short-delayed copy, so the gain can anticipate onsets.
            let dl = gdL[gdPos], dr = gdR[gdPos]
            gdL[gdPos] = Float(xl); gdR[gdPos] = Float(xr)
            gdPos += 1; if gdPos == gdLen { gdPos = 0 }

            var yl = Double(dl), yr = Double(dr)
            if !bypass {
                gCur += gStep
                yl *= gCur; yr *= gCur
            }

            // ---- True-peak lookahead limiter.
            let tp = bypass ? 0 : truePeak.peak(yl, yr)
            let req = Float(tp > ceiling ? ceiling / tp : 1)

            // sliding-window minimum of the requirement over the last (lookahead + 1) samples
            let cap = dqVal.count
            while dqCount > 0 {
                let back = (dqHead + dqCount - 1) % cap
                if dqVal[back] >= req { dqCount -= 1 } else { break }
            }
            dqVal[(dqHead + dqCount) % cap] = req
            dqIdx[(dqHead + dqCount) % cap] = sampleIndex
            dqCount += 1
            while dqIdx[dqHead] < sampleIndex - lookahead {
                dqHead = (dqHead + 1) % cap
                dqCount -= 1
            }
            let minReq = dqVal[dqHead]
            sampleIndex += 1

            // moving average of the minimum => linear attack ramp that reaches the target at the peak
            msSum += Double(minReq - msRing[msPos])
            msRing[msPos] = minReq
            msPos += 1; if msPos == lookahead { msPos = 0 }
            let smoothed = msSum / Double(lookahead)

            // slow release, instant (pre-ramped) attack
            let released = 1 - (1 - limGain) * relCoef
            limGain = min(smoothed, released)

            let ol = Double(limL[limPos]), or = Double(limR[limPos])
            limL[limPos] = Float(yl); limR[limPos] = Float(yr)
            limPos += 1; if limPos == lookahead { limPos = 0 }

            let g = bypass ? 1.0 : limGain
            left[n] = Float(max(-0.9995, min(0.9995, ol * g)))
            right[n] = Float(max(-0.9995, min(0.9995, or * g)))
        }
    }

    // MARK: - Control (once per block)

    private func control(_ cfg: LevelerConfig) {
        let dt = Double(block) / sr
        let eDb = Loudness.lufs(power: envP)
        let fDb = Loudness.lufs(power: fastP)
        var sDb = Loudness.lufs(power: slowP)

        // --- Presence (ITU-T P.56 style): signal counts as "present" while the 30 ms envelope is within
        // 15.9 dB of the tracked active level and above the silence gate. While absent, gain is frozen.
        let aboveGate = eDb > cfg.gateLufs
        if !slowValid && aboveGate {
            slowP = envP; sDb = eDb; slowValid = true; acquiring = true; acquireTime = 0
        }
        let present = aboveGate && (!slowValid || eDb > sDb - presenceMarginDb)
        quietTime = present ? 0 : quietTime + dt
        let hangover = quietTime < presenceHangoverS
        let longPause = quietTime > holdS            // treat as a new scene and re-acquire
        let wasTracking = tracking
        tracking = aboveGate && (present || hangover || longPause)
        if tracking && !wasTracking && longPause { acquiring = true; acquireTime = 0 }

        // Fast acquisition after start-up / scene change: use the momentary-style time constant until close.
        if acquiring && tracking {
            sRise = aSlowAcquire; sFall = aSlowAcquire
            acquireTime += dt
            if abs(sDb - eDb) < 3 || acquireTime > 1.5 { acquiring = false }
        } else if !acquiring {
            aSlow = 1 - exp(-1 / (max(cfg.levelWindowS, 0.05) * sr))
            sRise = aSlow; sFall = aSlow
        }

        currentLevelLufs = Float(sDb)

        if cfg.bypass {
            gStep = (1 - gCur) / Double(block)
            currentGainDb = 0; protectorGainDb = 0
            return
        }

        // --- Slow loop: static gain curve with a transparent zone, slew-limited.
        if slowValid {
            let gt = curve(sDb, cfg, softFloor: true)
            let delta = gt - gSlow
            let ratio = delta / max(cfg.adaptBandDb, 0.1)
            let speedUp = 1 + ratio * ratio
            if delta < 0 {
                let tau = cfg.fallTau0S / speedUp
                let step = max(delta * (1 - exp(-dt / tau)), -maxFallDbPerS * dt)
                gSlow += step
            } else if delta > 0 && tracking {
                let tau = cfg.riseTau0S / speedUp
                let step = min(delta * (1 - exp(-dt / tau)), maxRiseDbPerS * dt)
                gSlow += step
            }
        }

        // --- Fast guard (dual front-end AGC, fast component): total gain may not exceed the curve value for
        // (short-term loudness - slack). Instant attack, ~100 ms recovery.
        let limit = fDb > cfg.gateLufs ? curve(fDb - cfg.guardSlackDb, cfg, softFloor: false) : cfg.maxBoostDb
        let boostGuard = min(0, limit - gSlow)
        let mDb = Loudness.lufs(power: momP)
        let momExcess = mDb > cfg.gateLufs ? (mDb + gSlow) - (cfg.targetLufs + cfg.momentaryMarginDb) : 0
        let momGuard = -max(0, momExcess) * (1 - 1 / max(cfg.cutRatio, 1))
        let gfTarget = min(boostGuard, momGuard)
        if gfTarget < gFast {
            gFast = gfTarget
        } else {
            gFast += (gfTarget - gFast) * (1 - exp(-dt / protectorRecoveryS))
        }

        let total = gSlow + gFast
        gStep = (lin(total) - gCur) / Double(block)
        currentGainDb = Float(total)
        protectorGainDb = Float(gFast)
    }
}
