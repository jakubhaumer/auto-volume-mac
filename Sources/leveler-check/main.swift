import Foundation
import AutoVolumeCore

// DSP self-check (XCTest/Swift Testing need full Xcode). Run: swift run leveler-check
// Analysis mode: leveler-check <speech.wav> [gainDb]  -> measures gain wobble inside speech.

var sr = 48_000.0

func readWav(_ path: String) -> [Float] {
    let d = [UInt8](FileManager.default.contents(atPath: path) ?? Data())
    var i = 12
    var rate = 44_100.0
    while i + 8 < d.count {
        let id = String(bytes: d[i..<i+4], encoding: .ascii)!
        let sz = Int(d[i+4]) | Int(d[i+5]) << 8 | Int(d[i+6]) << 16 | Int(d[i+7]) << 24
        if id == "fmt " { rate = Double(Int(d[i+12]) | Int(d[i+13]) << 8 | Int(d[i+14]) << 16) }
        if id == "data" {
            sr = rate
            let n = min(sz, d.count - i - 8) / 2
            return (0..<n).map { Float(Int16(bitPattern: UInt16(d[i+8+2*$0]) | UInt16(d[i+9+2*$0]) << 8)) / 32768 }
        }
        i += 8 + sz + (sz & 1)
    }
    return []
}

if CommandLine.arguments.count > 1 {
    // Analysis: speech scaled to a steady level; measure effective gain wobble per 50 ms block.
    var x = readWav(CommandLine.arguments[1])
    let inDb: Float = CommandLine.arguments.count > 2 ? Float(CommandLine.arguments[2])! : -30
    let cur = 10 * log10f(x.reduce(Float(0)) { $0 + $1 * $1 } / Float(x.count))
    let k = powf(10, (inDb - cur) / 20)
    for i in 0..<x.count { x[i] *= k }
    // Optional background noise floor (dB relative to speech), e.g. -28: room tone / music bed in pauses.
    if CommandLine.arguments.count > 3, let rel = Float(CommandLine.arguments[3]) {
        let amp = powf(10, (inDb + rel) / 20) * 1.7
        var seed: UInt32 = 12345
        for i in 0..<x.count {
            seed = seed &* 1664525 &+ 1013904223
            x[i] += amp * (Float(seed >> 8) / Float(1 << 24) - 0.5)
        }
    }
    // Emphasis test: a 2 s phrase (7.0-9.0 s) is 8 dB louder, like a stressed phrase.
    let swellDb: Float = 8
    let swellFrom = Int(7.0 * sr), swellTo = Int(9.0 * sr)
    for i in swellFrom..<min(swellTo, x.count) { x[i] *= powf(10, swellDb / 20) }
    let src = x
    // Run the file 3x back-to-back so the AGC is settled, analyse the last pass.
    let lv = Leveler(sampleRate: sr)
    var out = [Float](); var all = [Float]()
    for pass in 0..<3 { var y = src; var r = y
        y.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            var off = 0
            while off < lp.count { let c = min(512, lp.count - off)
                lv.process(left: lp.baseAddress! + off, right: rp.baseAddress! + off, frames: c); off += c } } }
        if pass == 2 { out = y }
        all += y
    }
    let d = lv.latencyFrames
    let blk = Int(sr * 0.05)
    var gains = [Float]()
    var gIn = [Float](), gOut = [Float]()
    var bIn = [Float](), bGain = [Float]()
    var b = 0
    while (b + 1) * blk + d < out.count {
        let a = src[(b * blk)..<((b + 1) * blk)]
        let o = out[(b * blk + d)..<((b + 1) * blk + d)]
        let ia = rmsDb(a), oa = rmsDb(o)
        bIn.append(ia); bGain.append(ia > -50 ? oa - ia : .nan)
        if ia > -50 {
            gains.append(oa - ia)
            let mid = b * blk + blk / 2
            if mid > swellFrom + Int(0.4 * sr) && mid < swellTo { gIn.append(oa - ia) }
            else if mid < swellFrom - Int(0.2 * sr) && mid > Int(3 * sr) { gOut.append(oa - ia) }
        }
        b += 1
    }
    let sorted = gains.sorted()
    func pct(_ p: Float) -> Float { sorted[Int(p * Float(sorted.count - 1))] }
    var maxStep: Float = 0
    for j in 1..<gains.count { maxStep = max(maxStep, abs(gains[j] - gains[j-1])) }
    let mean = gains.reduce(0, +) / Float(gains.count)
    let sd = sqrtf(gains.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(gains.count))
    print(String(format: "in %.0f dB | effective gain: mean %+.1f, sd %.2f dB, p5..p95 %+.1f..%+.1f (spread %.1f dB), max 50ms step %.1f dB",
                 inDb, mean, sd, pct(0.05), pct(0.95), pct(0.95) - pct(0.05), maxStep))
    // Pause-onset test: after a pause, the first 200 ms of speech must not be louder than later speech.
    func avgValid(_ x: ArraySlice<Float>) -> Float? {
        var sum: Float = 0
        var n = 0
        for v in x where !v.isNaN { sum += v; n += 1 }
        return n > 0 ? sum / Float(n) : nil
    }
    var overs = [Float]()
    var pos = 8
    while pos + 20 < bIn.count {
        var wasQuiet = bIn[pos] > -45
        for q in (pos - 8)..<pos where bIn[q] >= -45 { wasQuiet = false }
        if wasQuiet {
            if let first = avgValid(bGain[pos..<(pos + 4)]), let later = avgValid(bGain[(pos + 10)..<(pos + 20)]) {
                overs.append(first - later)
            }
            pos += 20
        } else { pos += 1 }
    }
    if !overs.isEmpty {
        var total: Float = 0
        var worst: Float = -100
        for v in overs { total += v; worst = max(worst, v) }
        print(String(format: "      pause onsets: %d found, speech start is %+.1f dB vs later in the phrase (avg), worst %+.1f dB",
                     overs.count, total / Float(overs.count), worst))
    }
    let mIn = gIn.reduce(0, +) / Float(max(gIn.count, 1)), mOut = gOut.reduce(0, +) / Float(max(gOut.count, 1))
    print(String(format: "      emphasis test: +%.0f dB phrase -> output rose %.1f dB (%.0f%% of the emphasis kept)",
                 swellDb, swellDb + (mIn - mOut), 100 * (swellDb + (mIn - mOut)) / swellDb))
    exit(0)
}
var failures = 0

func check(_ ok: Bool, _ msg: String) {
    print(ok ? "PASS" : "FAIL", msg)
    if !ok { failures += 1 }
}

func tone(seconds: Double, rmsDb: Float, phase: inout Double) -> [Float] {
    let n = Int(seconds * sr)
    let amp = powf(10, rmsDb / 20) * 2 // 0.5*(sin+sin) has RMS = amp/2
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = phase + Double(i) / sr
        out[i] = amp * 0.5 * (Float(sin(2 * .pi * 220 * t)) + Float(sin(2 * .pi * 1300 * t)))
    }
    phase += Double(n) / sr
    return out
}

func run(_ lv: Leveler, _ x: inout [Float]) {
    var r = x
    x.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
            var off = 0
            while off < lp.count {
                let c = min(512, lp.count - off)
                lv.process(left: lp.baseAddress! + off, right: rp.baseAddress! + off, frames: c)
                off += c
            }
        }
    }
}

func rmsDb(_ x: ArraySlice<Float>) -> Float {
    10 * log10f(max(x.reduce(Float(0)) { $0 + $1 * $1 } / Float(x.count), 1e-12))
}

// 1. Quiet (-40 dB) then loud (-12 dB) converge toward the -23 dB target.
do {
    let lv = Leveler(sampleRate: sr)
    var phase = 0.0
    var q = tone(seconds: 12, rmsDb: -40, phase: &phase); run(lv, &q)
    var l = tone(seconds: 12, rmsDb: -12, phase: &phase); run(lv, &l)
    let qo = rmsDb(q[(q.count - 48_000)...]), lo = rmsDb(l[(l.count - 48_000)...])
    print(String(format: "  quiet out %.1f dB, loud out %.1f dB", qo, lo))
    check(abs(qo + 23) <= 4, "quiet segment boosted to ~target")
    check(abs(lo + 23) <= 4, "loud segment reduced to ~target")
    check(abs(qo - lo) < 4, "quiet and loud within 4 dB of each other")
}

// 2. Very hot input never clips.
do {
    let lv = Leveler(sampleRate: sr)
    var phase = 0.0
    var x = tone(seconds: 3, rmsDb: -3, phase: &phase); run(lv, &x)
    check(x.map(abs).max()! <= 1.0, "limiter keeps hot input <= 1.0 (peak \(x.map(abs).max()!))")
}

// 3. Silence is not boosted.
do {
    let lv = Leveler(sampleRate: sr)
    var x = [Float](repeating: 0, count: 5 * 48_000); run(lv, &x)
    check(abs(lv.currentGainDb) < 0.001, "silence leaves gain at 0 dB")
}

// 4. Bypass is a pure delay.
do {
    var cfg = LevelerConfig(); cfg.bypass = true
    let lv = Leveler(sampleRate: sr, config: cfg)
    var phase = 0.0
    var x = tone(seconds: 0.5, rmsDb: -30, phase: &phase)
    let orig = x; run(lv, &x)
    let d = lv.latencyFrames
    var ok = true
    for i in d..<x.count where abs(x[i] - orig[i - d]) > 1e-5 { ok = false; break }
    check(ok, "bypass passes audio through unchanged (delayed \(d) frames)")
}

exit(failures == 0 ? 0 : 1)
