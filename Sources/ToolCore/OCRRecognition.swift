import Foundation
import Vision
import ImageIO

enum OCRRecognition {
    static func recognize(_ data: Data, keepLineBreaks: Bool = true) throws -> String {
        try autoreleasepool {
            guard data.count <= 40 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096
                  ] as CFDictionary) else {
                throw NSError(domain: "TactoraOCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "图片无效或超过 40 MB。"])
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: keepLineBreaks ? "\n" : " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
