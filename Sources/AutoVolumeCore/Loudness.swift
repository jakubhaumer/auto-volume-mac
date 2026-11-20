import Foundation

/// ITU-R BS.1770-5 K-weighting (shelving + RLB high-pass), derived for any sample rate.
///
/// The constants below reproduce the standard's published 48 kHz coefficients to ~1e-15
/// (verified against the BS.1770-5 table) and follow the bilinear-transform derivation used by
/// libebur128, which makes the filter exact at 44.1/96/… kHz as well.
public struct KWeighting {
    struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var z1 = 0.0, z2 = 0.0
        @inline(__always) mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var shelf = Biquad()
    private var highpass = Biquad()

    public init(sampleRate fs: Double) {
        // Stage 1: high-shelf (head acoustics).
        let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        var k = tan(Double.pi * f0 / fs)
        let a0 = 1 + k / q + k * k
        shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0,
                       b2: (vh - vb * k / q + k * k) / a0,
                       a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        // Stage 2: RLB high-pass.
        let q2 = 0.5003270373238773
        k = tan(Double.pi * 38.13547087602444 / fs)
        let a02 = 1 + k / q2 + k * k
        highpass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a02, a2: (1 - k / q2 + k * k) / a02)
    }

    @inline(__always) public mutating func process(_ x: Double) -> Double {
        highpass.process(shelf.process(x))
    }
}

/// Loudness helpers shared by the leveler, the tests and calibration tools.
public enum Loudness {
    /// BS.1770: L_K = -0.691 + 10 log10(power) for a power already summed over channels.
    @inline(__always) public static func lufs(power: Double) -> Double {
        -0.691 + 10 * log10(max(power, 1e-12))
    }

    /// Integrated, gated loudness of a stereo signal (BS.1770-5: 400 ms blocks, 75 % overlap,
    /// absolute gate -70 LKFS, relative gate -10 LU).
    public static func integrated(left: [Float], right: [Float], sampleRate: Double) -> Double {
        var kl = KWeighting(sampleRate: sampleRate), kr = KWeighting(sampleRate: sampleRate)
        let step = Int(sampleRate * 0.1)
        var stepPower = [Double]()
        var acc = 0.0, n = 0
        for i in 0..<min(left.count, right.count) {
            let a = kl.process(Double(left[i])), b = kr.process(Double(right[i]))
            acc += a * a + b * b
            n += 1
            if n == step { stepPower.append(acc / Double(step)); acc = 0; n = 0 }
        }
        guard stepPower.count >= 4 else { return -120 }
        var blocks = [Double]()
        for i in 0...(stepPower.count - 4) { blocks.append((stepPower[i] + stepPower[i + 1] + stepPower[i + 2] + stepPower[i + 3]) / 4) }
        let absGated = blocks.filter { lufs(power: $0) > -70 }
        guard !absGated.isEmpty else { return -120 }
        let relThreshold = lufs(power: absGated.reduce(0, +) / Double(absGated.count)) - 10
        let relGated = absGated.filter { lufs(power: $0) > relThreshold }
        guard !relGated.isEmpty else { return -120 }
        return lufs(power: relGated.reduce(0, +) / Double(relGated.count))
    }
}

/// 4x true-peak estimator (ITU-R BS.1770-5 Annex 2 interpolation filter: 48 taps, 4 phases).
public struct TruePeak {
    static let phases: [[Double]] = [
        [0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625, 0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500],
        [-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250, 0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375],
        [-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500, 0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875],
        [-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500, 0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750],
    ]

    private var histL = [Double](repeating: 0, count: 16)
    private var histR = [Double](repeating: 0, count: 16)
    private var pos = 0
    private let oversample: Bool

    /// Below 96 kHz the standard's 4x filter is used; at higher rates sample peak is already accurate.
    public init(sampleRate: Double) { oversample = sampleRate < 96_000 }

    /// Returns the true-peak magnitude (linear) around the newest stereo sample pair.
    @inline(__always) public mutating func peak(_ l: Double, _ r: Double) -> Double {
        var m = max(abs(l), abs(r))
        guard oversample else { return m }
        pos = (pos + 1) & 15
        histL[pos] = l; histR[pos] = r
        for p in 0..<4 {
            var sl = 0.0, sr = 0.0
            Self.phases[p].withUnsafeBufferPointer { h in
                for k in 0..<12 {
                    let idx = (pos - k) & 15
                    sl += h[k] * histL[idx]
                    sr += h[k] * histR[idx]
                }
            }
            m = max(m, abs(sl), abs(sr))
        }
        return m
    }
}
