import Foundation
import Vision
import AppKit
var output: [[String: Any]] = []
for path in CommandLine.arguments.dropFirst() {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US", "zh-Hans"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:]).perform([request])
    let strings = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    output.append(["file": path, "recognized": strings])
}
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
