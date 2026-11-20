# Research record: how Auto Volume decides what to do

Every design choice in `Leveler.swift` traces to a source or to a measurement made with the tools in this
repo. Evidence status:

* **[P]** read as raw text of the primary document (standard / report) extracted locally while building this.
* **[P\*]** primary document, but read through a fetch summariser (source code, manual page, README), not raw.
* **[S]** secondary: a search-result summary, vendor page or paper abstract. Consistent with other evidence, but
  not read at source.
* **[M]** our own measurement (`leveler-check`, reproducible; see "Reproducing").
* **[U]** looked for, not found / not verified. Listed under "Open questions".

## 1. Measuring loudness

| Fact | Source | Status |
|---|---|---|
| K-weighting = shelf (+4 dB above ~2 kHz) + 38 Hz high-pass; exact 48 kHz coefficients | ITU-R BS.1770-5, §2 | [P] |
| Our `KWeighting` (libebur128 derivation, any sample rate) reproduces those coefficients to 1e-15 | libebur128 `ebur128.c` + own check | [P\*][M] |
| Loudness `L = -0.691 + 10·log10(Σ channel power)`; gating on 400 ms blocks, 75 % overlap, −70 LKFS absolute, −10 LU relative | BS.1770-5 | [P] |
| The measure correlates r = 0.977 with listener judgements over 336 sequences (music, TV/film drama, sport, news, effects, ads, speech in several languages) | BS.1770-5 Annex 1 | [P] |
| Momentary = 400 ms window, Short-term = 3 s window, meters update ≥ 10 Hz | EBU Tech 3341 §2.2 | [P] |
| "The 3-second window nicely bridges most gaps between words and sentences" (stable voice level) | EBU Tech 3343 | [P] |
| Our meter passes EBU Tech 3341 test cases #1, #2, #3, #5 (±0.1 LU) | `leveler-check` | [M] |
| True peak = 4× oversampling, 48-tap 4-phase FIR (coefficients taken verbatim from the standard) | BS.1770-5 Annex 2 | [P] |
| Max true peak −1 dBTP, "may be lower for different distribution systems and data reduction rates" | EBU R 128 | [P] |
| Overshoot between a 4× true-peak reading and the analogue level is < 1 dB (typically a few tenths); non-lossless codecs add overshoot | EBU Tech 3344 | [P] |
| Netflix asks −2 dBTP and dialogue-gated loudness | Netflix sound-mix spec v1.5 | [S] |

**Decision:** detector = BS.1770 K-weighted power summed over L+R (replaces an 80 Hz one-pole on a mono mix);
output ceiling −2 dBTP (R 128 allows −1; lossy and Bluetooth links add overshoot).

## 2. Telling speech from pauses

| Fact | Source | Status |
|---|---|---|
| Active-speech threshold 15.9 dB below the active level; hangover 0.2 s; envelope time constant 0.03 s | ITU-T P.56, as specified in Kabal, McGill TSP report (1999) | [P] |
| A broadcast "silence gate" inhibits gain *increases* below a threshold "to prevent noise rush-up, holes, pumping, and breathing" | Orban Optimod 464A manual | [P\*] |
| WebRTC AGC2 only allows gain increases after ≥ 12 consecutive confident speech frames; decreases are never gated | `adaptive_digital_gain_controller.cc`, `agc2_common.h` | [P\*] |
| Same controller limits gain change to 6 dB/s (default) and caps gain by a noise level | `audio_processing.h` | [P\*] |

**Decision:** presence = 30 ms envelope within 15.9 dB of the tracked active level and above a −50 LUFS gate, with
200 ms hangover. While not present, gain is frozen (cuts still allowed); a pause longer than 2 s counts as a new
scene. Boost slew capped at 6 dB/s. The allowed boost fades out smoothly over 10 dB toward the gate, so a noise
floor near the gate is not boosted hard.

## 3. How fast and how much to correct

| Fact | Source | Status |
|---|---|---|
| Speech envelope modulation is 1–16 Hz, peak ≈ 4 Hz; intelligibility depends on envelope below ~8 Hz | Houtgast–Steeneken, Drullman (via reviews) | [S] |
| Dual front-end AGC: a slow component for overall level plus a fast component for sudden loud transients beat linear amplification and single-loop compression; fast recovery 80–150 ms, slow attack 150–325 ms | Moore, Glasberg & Stone, Br J Audiol 25:171 (1991), abstract | [S] |
| Fast compression lowers modulation depth; slow gain control (0.25–0.5 s and longer) preferred for speech | Plomp, JASA 83:2322 (1988), via TNO abstract | [S] |
| Short-term loudness integration ≈ 22 ms attack / 30 ms release (α 0.045 / 0.033 per 1 ms) | Moore et al. loudness model, as printed in Kolarik et al. (2026) | [P] |
| Leave the mix untouched when loudness-to-dialogue ratio ≤ 5 LU; real-time, non-guided DRC "potentially compromis[es] audio quality"; offline/lookahead processing preferred; time constants on the gain-control signal reduce on/off toggling | EBU Tech 3343 §9.4, R 128 s4 | [P] |
| Film dialogue adapted by sound engineers had LDR ≤ 5 LU; a 1.1 LU spread is "well within the range of audible acceptability" | EBU Tech 3343 §9.4 | [P] |
| Level discrimination for speech ≈ 2–4 dB | hearing-research summaries | [S] |
| Rising-level sounds are judged louder than falling ones (falling must be ~4 dB higher to match) | Ponsot et al. 2015, as cited | [S] |
| Offline Dynamic Audio Normalizer smooths gain over ±7.75 s with look-ahead to avoid pumping | project README | [P\*] |

**Decision (structure):** slow loop (K-weighted loudness, 2 s window) → static gain curve with a narrow untouched
zone → error-dependent speed (small errors corrected slowly so emphasis survives; big ones fast) → fast guard
(Moore-style fast component) that retracts boost the moment a loud event starts → true-peak lookahead limiter.

## 4. Limiter

| Fact | Source | Status |
|---|---|---|
| Attacks faster than ~1 ms add clicks/transient distortion; releases shorter than a bass period modulate the waveform; lookahead should span the lowest frequency's period | Sound On Sound, Audacity manual, limiter patents | [S] |

**Decision:** 10 ms lookahead with a linear attack ramp that reaches the required gain exactly at the peak
(sliding minimum + moving average), 150 ms release, 4× true-peak detection, L/R linked.

## 5. What was wrong before (measured on the previous version) [M]

* After a sudden loud scene the output stayed ~10 dB over target and crawled down for seconds; fast/slow "scene"
  modes switched with hysteresis (a kink in the gain trajectory).
* A noise floor above the old detector's gate could be tracked after long pauses and boosted.
* 80 Hz-HP mono detector instead of K-weighting; no true-peak control; 5 ms limiter lookahead.
* **Ruled out: dropouts.** Under 12 busy loops on a 10-core Mac the maximum IO callback gap stayed at exactly one
  buffer (10.7 ms) with zero empty or mismatched callbacks. Path latency ≈ 13 ms + 15 ms DSP.

## 6. Result (same speech clips, legacy vs current) [M]

| | legacy | current |
|---|---|---|
| Emphasis kept (+8 dB phrase) | 86 % | 83–90 % |
| Largest 50 ms gain step, normal speech | 0.31–0.34 dB | 0.28–0.30 dB |
| Output loudness spread over −40…−20 dB inputs | 0.1 dB | 2.9 dB (zone ±1 dB, ratio 30) |
| Pause-onset overshoot with room tone | ≤ +0.1 dB | ≤ +0.2 dB |
| Loud event → back within 3 dB | 7.7 s | 7.7 s |
| Back to quiet speech → within 3 dB of final | 8.4 s | 6.6 s |
| True peak on hot bass bursts | −9.3 dBTP (barely limited) | −2.75 dBTP (ceiling −2) |
| CPU | 0.63 % of one core | 0.29 % |

The consistent finding of the parameter sweeps: **anything that flattens loud events faster costs speech emphasis
and adds gain steps.** Momentary-guard margin 4 → 6 → 8 → 10 dB, speech at −20 dB RMS: emphasis kept
39 % → 62 % → 81 % → 87 %, largest gain step 3.1 → 1.6 → 0.8 → 0.7 dB. Speeding up the fall time had the same
effect while barely improving settling (7.6 s → 6.7 s). The defaults sit where speech stays natural; "Strong"
trades some of that for tighter leveling.

## 7. Open questions / limits (do not oversell)

1. **No lookahead on the slow loop.** A real-time leveler cannot know a loud scene is coming; EBU says as much.
   Adding 100+ ms of delay would help but desynchronises lip-sync (ITU-R BT.1359 detectability ≈ +45/−125 ms;
   sign conventions differ between sources) [S], and Bluetooth already adds delay players cannot see.
2. **Emphasis and a loud event look identical at onset** (a level rise); only magnitude and duration differ,
   hence the error-dependent speed. A dialogue detector was not attempted: the evidence gathered is for
   level-based control (Dolby's dialogue gating needs a licence; WebRTC's VAD is a trained network).
3. **Paywalled or unavailable:** Moore's long-term loudness constants, Stone & Moore (1992/2004), Plomp's
   modulation analysis, AES TD1008, Dolby DRC time constants. Only abstracts or secondary text were seen.
4. **Audibility of slow gain ramps in dB/s** was not found in the literature. The 6 dB/s rise cap comes from
   WebRTC's default; everything else from measurements.
5. **Test speech is text-to-speech plus synthetic scenes**, not film dialogue with music and effects. The numbers
   show the absence of the measured artifacts; they cannot show taste. Use `--bypass` for A/B listening.
6. **Bluetooth codec overshoot** evidence is anecdotal; −2 dBTP is a conservative choice.
7. A −50 LUFS gate means whispered dialogue below that level is left alone.

## Reproducing

```sh
swift build -c release
.build/release/leveler-check                    # standards + acceptance checks (pass/fail)
scripts/make-test-speech.sh                     # needs macOS `say`
.build/release/leveler-check compare .build/test-speech/sp.wav .build/test-speech/sp3.wav
LV_TM=8 LV_WIN=3 .build/release/leveler-check compare ...   # override parameters (see tunedConfig() in main.swift)
```
