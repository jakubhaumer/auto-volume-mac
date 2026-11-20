import Foundation
import AutoVolumeCore

// Objective evaluation of the leveler. Modes:
//   leveler-check                  standards checks + behaviour checks (pass/fail), exit 1 on failure
//   leveler-check compare <wav>    side-by-side metrics, legacy vs current, on speech (+ synthetic scenes)

let sr = 48_000.0
var failures = 0
func check(_ ok: Bool, _ msg: String) { print(ok ? "PASS" : "FAIL", msg); if !ok { failures += 1 } }

// MARK: - Signal helpers
var seed: UInt32 = 987654321
func noise() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 8) / Float(1 << 23) - 1 }

func sine(_ f: Double, dbfs: Double, seconds: Double) -> [Float] {
    let a = pow(10, dbfs / 20)
    return (0..<Int(seconds * sr)).map { Float(a * sin(2 * .pi * f * Double($0) / sr)) }
}
func rmsDb(_ x: ArraySlice<Float>) -> Float {
    10 * log10f(max(x.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(x.count, 1)), 1e-12))
}
func scaled(_ x: [Float], toRmsDb db: Float) -> [Float] {
    let k = powf(10, (db - rmsDb(x[...])) / 20); return x.map { $0 * k }
}

func readWav(_ path: String) -> [Float] {
    let d = [UInt8](FileManager.default.contents(atPath: path) ?? Data())
    var i = 12
    while i + 8 < d.count {
        let id = String(bytes: d[i..<i+4], encoding: .ascii) ?? ""
        let sz = Int(d[i+4]) | Int(d[i+5]) << 8 | Int(d[i+6]) << 16 | Int(d[i+7]) << 24
        if id == "data" {
            let n = min(sz, d.count - i - 8) / 2
            return (0..<n).map { Float(Int16(bitPattern: UInt16(d[i+8+2*$0]) | UInt16(d[i+9+2*$0]) << 8)) / 32768 }
        }
        i += 8 + sz + (sz & 1)
    }
    return []
}

// MARK: - Processor abstraction (legacy vs current)
struct Proc {
    let name: String
    let latency: Int
    let run: ([Float]) -> [Float]
}

func chunked(_ x: [Float], _ f: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Void) -> [Float] {
    var l = x, r = x
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        var o = 0
        while o < lp.count { let c = min(512, lp.count - o); f(lp.baseAddress! + o, rp.baseAddress! + o, c); o += c }
    } }
    return l
}
func envDouble(_ k: String) -> Double? { ProcessInfo.processInfo.environment[k].flatMap(Double.init) }
func tunedConfig() -> LevelerConfig {
    var c = LevelerConfig()
    if let v = envDouble("LV_TARGET") { c.targetLufs = v }
    if let v = envDouble("LV_T") { c.nullBandDb = v }
    if let v = envDouble("LV_RB") { c.boostRatio = v }
    if let v = envDouble("LV_RC") { c.cutRatio = v }
    if let v = envDouble("LV_BOOST") { c.maxBoostDb = v }
    if let v = envDouble("LV_CUT") { c.maxCutDb = v }
    if let v = envDouble("LV_SLACK") { c.guardSlackDb = v }
    if let v = envDouble("LV_GATE") { c.gateLufs = v }
    if let v = envDouble("LV_WIN") { c.levelWindowS = v }
    if let v = envDouble("LV_TM") { c.momentaryMarginDb = v }
    if let v = envDouble("LV_B") { c.adaptBandDb = v }
    if let v = envDouble("LV_TR") { c.riseTau0S = v }
    if let v = envDouble("LV_TF") { c.fallTau0S = v }
    return c
}
func current(_ cfg: LevelerConfig = tunedConfig()) -> Proc {
    let lv = Leveler(sampleRate: sr, config: cfg)
    return Proc(name: "current", latency: lv.latencyFrames) { x in chunked(x) { lv.process(left: $0, right: $1, frames: $2) } }
}
func legacy() -> Proc {
    let lv = LegacyLeveler(sampleRate: sr)
    return Proc(name: "legacy ", latency: lv.latencyFrames) { x in chunked(x) { lv.process(left: $0, right: $1, frames: $2) } }
}

// K-weighted momentary loudness series (400 ms window, 100 ms hop) of a mono signal duplicated to L/R
func momentary(_ x: [Float]) -> [Double] {
    var k = KWeighting(sampleRate: sr), k2 = KWeighting(sampleRate: sr)
    let hop = Int(sr * 0.1)
    var steps = [Double](); var acc = 0.0
    for (i, v) in x.enumerated() {
        let a = k.process(Double(v)), b = k2.process(Double(v)); acc += a * a + b * b
        if (i + 1) % hop == 0 { steps.append(acc / Double(hop)); acc = 0 }
    }
    guard steps.count >= 4 else { return [] }
    return (0...(steps.count - 4)).map { Loudness.lufs(power: (steps[$0] + steps[$0+1] + steps[$0+2] + steps[$0+3]) / 4) }
}

let mode = CommandLine.arguments.dropFirst().first

// MARK: - Mode: standards + behaviour checks
if mode == nil {
    print("— Standards (EBU Tech 3341 minimum-requirement test signals, ITU-R BS.1770-5) —")
    func integrated(_ x: [Float]) -> Double { Loudness.integrated(left: x, right: x, sampleRate: sr) }
    check(abs(integrated(sine(1000, dbfs: -23, seconds: 20)) + 23) <= 0.1, "Tech 3341 #1: stereo 1 kHz -23 dBFS => -23.0 ±0.1 LUFS")
    check(abs(integrated(sine(1000, dbfs: -33, seconds: 20)) + 33) <= 0.1, "Tech 3341 #2: stereo 1 kHz -33 dBFS => -33.0 ±0.1 LUFS")
    let t3 = sine(1000, dbfs: -36, seconds: 10) + sine(1000, dbfs: -23, seconds: 60) + sine(1000, dbfs: -36, seconds: 10)
    check(abs(integrated(t3) + 23) <= 0.1, "Tech 3341 #3: relative gating (-36/-23/-36) => -23.0 ±0.1 LUFS")
    let t5 = sine(1000, dbfs: -26, seconds: 20) + sine(1000, dbfs: -20, seconds: 20.1) + sine(1000, dbfs: -26, seconds: 20)
    check(abs(integrated(t5) + 23) <= 0.1, "Tech 3341 #5: three-tone gating => -23.0 ±0.1 LUFS")
    var tp = TruePeak(sampleRate: sr)
    var worstTp = 0.0
    for v in sine(997, dbfs: -6, seconds: 1) { worstTp = max(worstTp, tp.peak(Double(v), Double(v))) }
    check(abs(20 * log10(worstTp) + 6) < 0.15, "true-peak of a -6 dBFS sine reads -6 dBTP ±0.15 (got \(String(format: "%.2f", 20 * log10(worstTp))))")

    print("— Leveler behaviour (acceptance criteria from docs/RESEARCH.md) —")
    // Speech-like test signal: 220 Hz + 1.3 kHz carriers, 4 Hz syllabic envelope with ~14 dB depth.
    func syllabic(_ seconds: Double, rmsDb: Double) -> [Float] {
        var x = [Float](repeating: 0, count: Int(seconds * sr))
        for i in 0..<x.count {
            let t = Double(i) / sr
            let env = pow(10, (-14 * (0.5 - 0.5 * sin(2 * .pi * 4 * t))) / 20)   // 0 .. -14 dB
            x[i] = Float(env * (sin(2 * .pi * 220 * t) + 0.6 * sin(2 * .pi * 1300 * t)))
        }
        return scaled(x, toRmsDb: Float(rmsDb))
    }
    func blocks50(_ x: [Float]) -> [Float] { (0..<(x.count / 2400)).map { rmsDb(x[($0 * 2400)..<(($0 + 1) * 2400)]) } }

    do { // quiet vs loud scenes converge close to target
        let p = current()
        let quiet = p.run(sine(300, dbfs: -38, seconds: 15)); let loud = p.run(sine(300, dbfs: -14, seconds: 15))
        let q = momentary(Array(quiet.suffix(Int(2 * sr)))).last ?? -99, l = momentary(Array(loud.suffix(Int(2 * sr)))).last ?? -99
        print(String(format: "  quiet scene settles at %.1f LUFS, loud scene at %.1f LUFS (target -19)", q, l))
        check(abs(q + 19) <= 4 && abs(l + 19) <= 4, "quiet (-39 LUFS, within the +18 dB boost range) and loud (-15 LUFS) scenes both settle within 4 LU of target")
    }
    do { // syllabic speech: no gain modulation at the syllable rate
        let p = current(); let x = syllabic(20, rmsDb: -34)
        let y = p.run(x)
        let giAll = blocks50(x), goAll = blocks50(Array(y.dropFirst(p.latency)))
        var g = [Float](); for i in 0..<min(giAll.count, goAll.count) { g.append(goAll[i] - giAll[i]) }
        g = Array(g.suffix(160))
        var maxStep: Float = 0; for i in 1..<g.count { maxStep = max(maxStep, abs(g[i] - g[i-1])) }
        check(maxStep < 0.6, String(format: "steady syllabic speech: largest 50 ms gain step %.2f dB (< 0.6 dB, i.e. no pumping)", maxStep))
    }
    do { // emphasis: a 2 s phrase 8 dB louder keeps most of its emphasis
        let p = current(); var x = syllabic(24, rmsDb: -30)
        for i in Int(14 * sr)..<Int(16 * sr) { x[i] *= powf(10, 8.0 / 20) }
        let y = p.run(x)
        let gi = blocks50(x), go = blocks50(Array(y.dropFirst(p.latency)))
        func avg(_ a: Int, _ b: Int) -> Float { var s: Float = 0; for i in a..<b { s += go[i] - gi[i] }; return s / Float(b - a) }
        let kept = 8 + (avg(Int(14.4 * 20), Int(16 * 20)) - avg(Int(10 * 20), Int(13.8 * 20)))
        check(kept >= 6.0, String(format: "emphasis: +8 dB phrase keeps %.1f dB of its emphasis (≥ 6.0 = 75%%)", kept))
    }
    do { // pause onset: gain must not creep up during pauses (room tone present)
        let p = current(); var x = [Float]()
        for _ in 0..<6 { x += syllabic(2.0, rmsDb: -32); x += (0..<Int(2.6 * sr)).map { _ in noise() * 0.0004 } }
        let y = p.run(x)
        var worst: Float = -99
        let seg = Int((2.0 + 2.6) * sr)
        for k in 2..<6 {
            let on = k * seg + p.latency
            let gIn = rmsDb(x[(k * seg)..<(k * seg + 12000)]), gOut = rmsDb(y[on..<(on + 12000)])
            let lIn = rmsDb(x[(k * seg + 36000)..<(k * seg + 48000)]), lOut = rmsDb(y[(on + 36000)..<(on + 48000)])
            worst = max(worst, (gOut - gIn) - (lOut - lIn))
        }
        check(worst < 1.0, String(format: "pause onsets: speech start vs later in phrase %+.2f dB (< 1 dB, no creep during pauses)", worst))
    }
    do { // loud event after boosted quiet speech: boost must be retracted at once (no blast)
        let p = current(); var x = syllabic(10, rmsDb: -42)
        let ev = x.count
        for i in 0..<Int(3 * sr) { let t = Double(i) / sr; x.append(noise() * 0.28 + Float(sin(2 * .pi * 55 * t)) * 0.22) }
        let y = p.run(x)
        var maxOut = -99.0, maxIn = -99.0
        var kO = KWeighting(sampleRate: sr), kO2 = KWeighting(sampleRate: sr), kI = KWeighting(sampleRate: sr), kI2 = KWeighting(sampleRate: sr)
        var aO = 0.0, aI = 0.0
        let w = Int(0.05 * sr)
        for i in 0..<Int(1.0 * sr) {
            let o = Double(y[ev + p.latency + i]), n = Double(x[ev + i])
            let a = kO.process(o), b = kO2.process(o); aO += a * a + b * b
            let c = kI.process(n), d = kI2.process(n); aI += c * c + d * d
            if (i + 1) % w == 0 { maxOut = max(maxOut, Loudness.lufs(power: aO / Double(w))); maxIn = max(maxIn, Loudness.lufs(power: aI / Double(w))); aO = 0; aI = 0 }
        }
        check(maxOut <= maxIn + 1.0, String(format: "sudden loud event: output never louder than the event itself (+%.1f dB vs natural, ≤ +1 dB)", maxOut - maxIn))
    }
    do { // hot input never exceeds the true-peak ceiling
        let p = current()
        var x = [Float](); let a = sine(60, dbfs: -2, seconds: 6), b = sine(1000, dbfs: -4, seconds: 6)
        for i in 0..<a.count { x.append(a[i] * 0.7 + b[i] * 0.6) }
        let y = p.run(x)
        var t = TruePeak(sampleRate: sr); var m = 0.0
        for v in y[Int(sr)...] { m = max(m, t.peak(Double(v), Double(v))) }
        check(20 * log10(m) <= -2 + 0.2, "true peak of hot bass+tone stays ≤ ceiling -2 dBTP (+0.2): \(String(format: "%.2f", 20 * log10(m))) dBTP")
    }
    do { // silence is not boosted
        let p = current(); let y = p.run([Float](repeating: 0, count: Int(5 * sr)))
        check(y.allSatisfy { $0 == 0 }, "digital silence stays silent")
    }
    do { // room tone alone (below the gate) is never boosted
        let p = current(); let x = (0..<Int(20 * sr)).map { _ in noise() * 0.003 }   // ≈ -57 dBFS
        let y = p.run(x)
        let d = rmsDb(y.suffix(Int(sr))) - rmsDb(x.suffix(Int(sr)))
        check(abs(d) < 1.0, String(format: "room tone at the gate (-51 LUFS) is not boosted (Δ %.2f dB, < 1 dB)", d))
    }
    do { // bypass is a pure delay
        var cfg = LevelerConfig(); cfg.bypass = true
        let p = current(cfg); let x = sine(440, dbfs: -20, seconds: 0.5); let y = p.run(x)
        var ok = true
        for i in p.latency..<x.count where abs(y[i] - x[i - p.latency]) > 1e-5 { ok = false; break }
        check(ok, "bypass is a bit-exact delay of \(p.latency) frames (\(String(format: "%.1f", Double(p.latency) / sr * 1000)) ms)")
    }
    do { // transparency inside the null band
        let p = current(); let x = sine(300, dbfs: -18.3, seconds: 20)   // ≈ -19 LUFS: inside the zone
        let y = p.run(x)
        let d = rmsDb(y.suffix(Int(sr))) - rmsDb(x.suffix(Int(sr)))
        check(abs(d) < 0.3, String(format: "level inside the null band is left untouched (Δ %.2f dB)", d))
    }
    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Mode: compare
guard mode == "compare", CommandLine.arguments.count > 2 else { print("usage: leveler-check [compare <speech.wav>]"); exit(2) }
let speech0 = readWav(CommandLine.arguments[2])
let blk = Int(sr * 0.05)

func measure(_ p: Proc, _ src: [Float], swell: ClosedRange<Double>?, label: String) {
    // Run the clip 3x so the leveler is settled; analyse the last pass.
    var long = src + src + src
    _ = long.count
    let all = p.run(long)
    long = []
    let out = Array(all.suffix(src.count))
    let d = p.latency
    var gains = [Float](), bIn = [Float](), bGain = [Float]()
    var gSwellIn = [Float](), gSwellOut = [Float]()
    var b = 0
    while (b + 1) * blk + d < out.count {
        let ia = rmsDb(src[(b * blk)..<((b + 1) * blk)]), oa = rmsDb(out[(b * blk + d)..<((b + 1) * blk + d)])
        bIn.append(ia); bGain.append(ia > -50 ? oa - ia : .nan)
        if ia > -50 {
            gains.append(oa - ia)
            if let sw = swell {
                let t = (Double(b) + 0.5) * 0.05
                if t > sw.lowerBound + 0.4 && t < sw.upperBound { gSwellIn.append(oa - ia) }
                else if t < sw.lowerBound - 0.2 && t > 3 { gSwellOut.append(oa - ia) }
            }
        }
        b += 1
    }
    let mean = gains.reduce(0, +) / Float(gains.count)
    let outLufs = Loudness.integrated(left: Array(out.dropFirst(d)), right: Array(out.dropFirst(d)), sampleRate: sr)
    let sd = sqrtf(gains.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(gains.count))
    var maxStep: Float = 0
    for j in 1..<gains.count { maxStep = max(maxStep, abs(gains[j] - gains[j-1])) }
    var line = String(format: "  %@ %@ | out %.1f LUFS, mean gain %+5.1f dB, sd %.2f, max 50 ms step %.2f dB", p.name, label, outLufs, mean, sd, maxStep)
    if swell != nil, !gSwellIn.isEmpty, !gSwellOut.isEmpty {
        let kept = 8 + (gSwellIn.reduce(0, +) / Float(gSwellIn.count) - gSwellOut.reduce(0, +) / Float(gSwellOut.count))
        line += String(format: ", emphasis kept %.0f%%", 100 * kept / 8)
    }
    // pause onsets
    func avgValid(_ x: ArraySlice<Float>) -> Float? { var s: Float = 0; var n = 0; for v in x where !v.isNaN { s += v; n += 1 }; return n > 0 ? s / Float(n) : nil }
    var overs = [Float](); var pos = 8
    while pos + 20 < bIn.count {
        var quiet = bIn[pos] > -45
        for q in (pos - 8)..<pos where bIn[q] >= -45 { quiet = false }
        if quiet, let f = avgValid(bGain[pos..<(pos + 4)]), let l = avgValid(bGain[(pos + 10)..<(pos + 20)]) { overs.append(f - l); pos += 20 } else { pos += 1 }
    }
    if !overs.isEmpty { line += String(format: ", pause-onset %+.1f dB (worst %+.1f, n=%d)", overs.reduce(0, +) / Float(overs.count), overs.max()!, overs.count) }
    print(line)
}

func speechWithEmphasis(_ x: [Float]) -> [Float] {
    var y = x; let a = Int(7.0 * sr), b = min(Int(9.0 * sr), x.count)
    for i in a..<b { y[i] *= powf(10, 8.0 / 20) }
    return y
}

// Resample speech (44.1k wav) naive to 48k not needed: tools treat file rate as sr; speech timing scales 8% — fine for metrics.
for level in [-40.0, -30.0, -20.0] {
    print("\n== speech at \(Int(level)) dB RMS (steady, 1 pass settle) ==")
    let sp = speechWithEmphasis(scaled(speech0, toRmsDb: Float(level)))
    for p in [legacy(), current()] { measure(p, sp, swell: 7.0...9.0, label: "") }
}
print("\n== speech with long pauses (sp3) + room tone ==")
if CommandLine.arguments.count > 3 {
    let s3 = scaled(readWav(CommandLine.arguments[3]), toRmsDb: -30)
    for rel in [Float(-60), -20, -12] {
        var n = s3
        let amp = powf(10, (-30 + rel) / 20) * 1.7
        for i in 0..<n.count { n[i] += amp * noise() * 0.5 }
        for p in [legacy(), current()] { measure(p, n, swell: nil, label: "noise \(Int(rel)) dB") }
    }
}

// Scene changes: quiet speech -> loud event -> quiet speech
func scene(_ p: Proc) {
    let sp = scaled(speech0, toRmsDb: -42)
    var x = Array(sp.prefix(Int(8 * sr)))
    let eventStart = x.count
    for i in 0..<Int(8 * sr) {
        let t = Double(i) / sr
        x.append(noise() * 0.28 + Float(sin(2 * .pi * 55 * t)) * 0.22 + Float(sin(2 * .pi * 110 * t)) * 0.12)
    }
    let quietStart = x.count
    x += Array(sp.prefix(Int(10 * sr)))
    let y = p.run(x)
    let m = momentary(Array(y.dropFirst(p.latency)))
    func at(_ s: Double) -> Double { m[min(m.count - 1, Int(s * 10))] }
    let evT = Double(eventStart) / sr, qT = Double(quietStart) / sr
    if ProcessInfo.processInfo.environment["LV_TRACE"] != nil {
        var line = "      trace (LUFS, every 0.5 s from event-1 s): "
        var t = evT - 1.0
        while t < qT + 6 { line += String(format: "%.0f ", at(t)); t += 0.5 }
        print(line)
    }
    // 100 ms K-weighted loudness of the first second of the event ("blast" metric)
    var blast = -100.0
    do {
        var k1 = KWeighting(sampleRate: sr), k2 = KWeighting(sampleRate: sr)
        let w = Int(0.1 * sr); let st = eventStart + p.latency
        var acc = 0.0
        for i in 0..<Int(1.2 * sr) {
            let v = Double(y[st + i]); let a = k1.process(v), b = k2.process(v); acc += a * a + b * b
            if (i + 1) % (w / 2) == 0 { if i + 1 >= w { blast = max(blast, Loudness.lufs(power: acc / Double(w / 2) / 2)) }; acc = 0 }
        }
    }
    var worst = -100.0, settleLoud = -1.0
    let finalLoud = at(evT + 7.8)
    for k in 0..<30 { let v = at(evT + Double(k) * 0.1); worst = max(worst, v) }
    for k in 0..<78 where settleLoud < 0 { if abs(at(evT + Double(k) * 0.1) - finalLoud) < 3 { settleLoud = Double(k) * 0.1 } }
    var settleQuiet = -1.0
    let finalQuiet = at(qT + 9.5)
    for k in 0..<95 where settleQuiet < 0 { if abs(at(qT + Double(k) * 0.1) - finalQuiet) < 3 { settleQuiet = Double(k) * 0.1 } }
    print(String(format: "      blast (peak 50 ms loudness in first 1.2 s): %.1f LUFS = %+.1f dB over settled", blast, blast - finalLoud))
    print(String(format: "  %@ loud event: peak momentary %.1f LUFS vs settled %.1f (overshoot %+.1f dB), within 3 dB after %.1f s | back to quiet: within 3 dB of final (%.1f) after %.1f s",
                 p.name, worst, finalLoud, worst - finalLoud, settleLoud, finalQuiet, settleQuiet))
}
print("\n== scene changes (quiet speech -> sudden loud event -> quiet speech) ==")
scene(legacy()); scene(current())

// Limiter distortion on hot bass bursts
func limiterTest(_ p: Proc) {
    var x = [Float]()
    for i in 0..<Int(10 * sr) {
        let t = Double(i) / sr
        let burst: Float = (Int(t * 2) % 2 == 0) ? 1.0 : 0.35
        x.append(burst * (0.55 * Float(sin(2 * .pi * 60 * t)) + 0.35 * Float(sin(2 * .pi * 1000 * t))))
    }
    let y = p.run(x)
    var tp = TruePeak(sampleRate: sr); var peak = 0.0
    for v in y[Int(sr)...] { peak = max(peak, tp.peak(Double(v), Double(v))) }
    var clamp = 0; for v in y where abs(v) >= 0.999 { clamp += 1 }
    func g(_ s: ArraySlice<Float>, _ f: Double) -> Double {
        let w = 2 * Double.pi * f / sr; var re = 0.0, im = 0.0
        for (i, v) in s.enumerated() { re += Double(v) * cos(w * Double(i)); im += Double(v) * sin(w * Double(i)) }
        return 2 * hypot(re, im) / Double(s.count)
    }
    let seg = y[Int(6 * sr)..<Int(10 * sr)]
    var harm = 0.0; for h in [120.0, 180, 240, 300, 360, 420, 540] { harm += pow(g(seg, h), 2) }
    var side = 0.0; for f in [1060.0, 940, 1120, 880, 2000, 3000, 4000] { side += pow(g(seg, f), 2) }
    print(String(format: "  %@ true-peak %.2f dBTP, hard-clamped samples %d, 60 Hz harmonics %.0f dB, 1 kHz sidebands %.0f dB (rel. fundamentals)",
                 p.name, 20 * log10(peak), clamp, 10 * log10(max(harm, 1e-18)) - 20 * log10(g(seg, 60)),
                 10 * log10(max(side, 1e-18)) - 20 * log10(g(seg, 1000))))
}
print("\n== limiter on hot bass bursts (lower dB = cleaner) ==")
limiterTest(legacy()); limiterTest(current())

// CPU cost
func cpu(_ p: Proc) {
    let x = scaled(speech0, toRmsDb: -30)
    var total = x; for _ in 0..<4 { total += x }
    let t0 = Date(); _ = p.run(total); let dt = Date().timeIntervalSince(t0)
    print(String(format: "  %@ %.1f s of audio in %.3f s  => %.2f%% of one core", p.name, Double(total.count) / sr, dt, 100 * dt / (Double(total.count) / sr)))
}
print("\n== CPU ==")
cpu(legacy()); cpu(current())
