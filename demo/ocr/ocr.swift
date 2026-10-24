// Reads a PNG and prints every recognised text line with its pixel box (top-left origin) as JSON.
// Build: swiftc -O demo/ocr/ocr.swift -o demo/ocr/ocr     Run: demo/ocr/ocr screenshot.png [x y w h]
import AppKit
import Vision

guard CommandLine.arguments.count > 1,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: ocr image.png\n".data(using: .utf8)!)
    exit(1)
}
let w = Double(cg.width), h = Double(cg.height)
let request = VNRecognizeTextRequest()
request.recognitionLevel = ProcessInfo.processInfo.environment["OCR_FAST"] == nil ? .accurate : .fast
request.usesLanguageCorrection = false
// Optional region in pixels (top-left origin): ocr image.png x y w h, used to re-read a strip OCR skipped.
let a = CommandLine.arguments
if a.count >= 6, var x = Double(a[2]), var y = Double(a[3]), var rw = Double(a[4]), var rh = Double(a[5]) {
    x = max(0, min(x, w - 1)); y = max(0, min(y, h - 1)); rw = max(1, min(rw, w - x)); rh = max(1, min(rh, h - y))
    request.regionOfInterest = CGRect(x: x / w, y: 1 - (y + rh) / h, width: rw / w, height: rh / h)
}
try VNImageRequestHandler(cgImage: cg).perform([request])
var out: [[String: Any]] = []
for obs in request.results ?? [] {
    guard let best = obs.topCandidates(1).first else { continue }
    var b = obs.boundingBox
    let roi = request.regionOfInterest
    b = CGRect(x: roi.minX + b.minX * roi.width, y: roi.minY + b.minY * roi.height, width: b.width * roi.width, height: b.height * roi.height)
    out.append(["t": best.string, "c": Double(best.confidence),
                "x": (b.minX * w).rounded(), "y": ((1 - b.maxY) * h).rounded(),
                "w": (b.width * w).rounded(), "h": (b.height * h).rounded()])
}
let json = try JSONSerialization.data(withJSONObject: ["width": w, "height": h, "items": out])
FileHandle.standardOutput.write(json)
