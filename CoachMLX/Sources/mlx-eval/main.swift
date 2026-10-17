import CoachKit
import CoachMLX
import Foundation

// Usage: mlx-eval [--model 4b|1b] [--runs 2] [--persona steady,overreaching] [--show] [--out path]

var model = OnDeviceModel.gemma4B
var runs = 2
var personas = Persona.allCases
var show = false
var outPath: String?
var prefill = 64
var kvBits: Int?

var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--model": model = args.next() == "1b" ? .gemma1B : .gemma4B
    case "--runs": runs = Int(args.next()!)!
    case "--persona": personas = args.next()!.split(separator: ",").map { Persona(rawValue: String($0))! }
    case "--show": show = true
    case "--out": outPath = args.next()
    case "--prefill": prefill = Int(args.next()!)!
    case "--kvbits": kvBits = Int(args.next()!)!
    default: fatalError("unknown arg \(a)")
    }
}

let client = MLXClient(model: model, prefillStep: prefill, kvBits: kvBits) { p in
    if p < 1 { FileHandle.standardError.write("\rdownloading \(Int(p * 100))%".data(using: .utf8)!) }
}
let t0 = Date()
try await client.preload()
print("loaded \(client.name) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
print("after load: peak \(MLXClient.peakMemory / 1_000_000) MB")
try await runEval(coaches: [(client.name, client)], personas: personas, runs: runs, show: show, outPath: outPath)
print("PEAK_MB \(MLXClient.peakMemory / 1_000_000) prefill=\(prefill) kvBits=\(kvBits.map(String.init) ?? "none")")
