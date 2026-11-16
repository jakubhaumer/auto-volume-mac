import Foundation
import AutoVolumeCore

let usage = """
auto-volume — keep system audio at a steady loudness (macOS 14.2+)

USAGE: auto-volume [options]

OPTIONS:
  --target <dB>      Target loudness in dBFS RMS            (default -23)
  --max-boost <dB>   Max gain added to quiet parts          (default 18)
  --max-cut <dB>     Max gain removed from loud parts       (default 20)
  --ratio <n>        Fast compressor ratio for sudden peaks (default 3)
  --bypass           Pass audio through unprocessed (A/B test)
  --verbose          Print live level/gain once per second
  -h, --help         Show this help

Press Ctrl-C to stop; normal audio is restored automatically.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

var config = LevelerConfig()
var verbose = false

var args = CommandLine.arguments.dropFirst().makeIterator()
func floatArg(_ name: String) -> Float {
    guard let v = args.next(), let f = Float(v) else { fail("\(name) needs a number") }
    return f
}

while let arg = args.next() {
    switch arg {
    case "--target": config.targetDb = floatArg(arg)
    case "--max-boost": config.maxBoostDb = floatArg(arg)
    case "--max-cut": config.maxCutDb = floatArg(arg)
    case "--ratio": config.ratio = floatArg(arg)
    case "--bypass": config.bypass = true
    case "--verbose", "-v": verbose = true
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        fail("unknown option \(arg)\n\n\(usage)")
    }
}

guard config.targetDb < -3, config.targetDb > -50 else { fail("--target must be between -50 and -3") }
guard config.maxBoostDb >= 0, config.maxCutDb >= 0 else { fail("--max-boost/--max-cut must be >= 0") }

let engine = AudioTapEngine(config: config, verbose: verbose)

do {
    try engine.start()
} catch {
    FileHandle.standardError.write(Data("""
    Could not start: \(error)
    If this is a permission problem, allow your terminal under
    System Settings → Privacy & Security → Screen & System Audio Recording
    (System Audio Recording Only), then run again.

    """.utf8))
    exit(1)
}

// Clean shutdown: destroying the tap restores the original audio path.
var sources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        engine.stop()
        print("\nStopped. Audio restored.")
        exit(0)
    }
    src.resume()
    sources.append(src)
}

dispatchMain()
