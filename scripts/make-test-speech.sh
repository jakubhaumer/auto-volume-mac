#!/bin/sh
# Generates the speech clips used by `leveler-check compare` (macOS text-to-speech, mono 44.1 kHz WAV).
#   scripts/make-test-speech.sh [out-dir]      then:   .build/release/leveler-check compare <dir>/sp.wav <dir>/sp3.wav
set -e
OUT="${1:-.build/test-speech}"
mkdir -p "${OUT:?}"
say -v Samantha -o "${OUT:?}/sp.aiff" "When the director finally walked onto the stage, nobody expected what came next. She paused, looked at the crowd, and said very quietly, that everything they believed was wrong. Then, with a sudden burst of energy, she shouted that tomorrow would change everything! The audience gasped, and then, slowly, began to applaud."
say -v Samantha -o "${OUT:?}/sp3.aiff" "Good evening. [[slnc 2500]] I have something important to tell you. [[slnc 3000]] It will only take a minute. [[slnc 2200]] First, the results are in. [[slnc 3500]] And they are better than anyone expected. [[slnc 2500]] Thank you all for coming tonight."
afconvert -f WAVE -d LEI16@44100 -c 1 "${OUT:?}/sp.aiff" "${OUT:?}/sp.wav"
afconvert -f WAVE -d LEI16@44100 -c 1 "${OUT:?}/sp3.aiff" "${OUT:?}/sp3.wav"
rm -f "${OUT:?}/sp.aiff" "${OUT:?}/sp3.aiff"
echo "wrote ${OUT}/sp.wav and ${OUT}/sp3.wav"
