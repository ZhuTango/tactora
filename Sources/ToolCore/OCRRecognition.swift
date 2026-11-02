import Foundation
import Vision
import ImageIO

enum OCRRecognition {
    static func recognize(_ data: Data, keepLineBreaks: Bool) throws -> String {
        try recognize(data, mode: keepLineBreaks ? .original : .singleLine)
    }
    static func recognize(_ data: Data, mode: OCRLineBreakMode = .smart) throws -> String {
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
            let lines = (request.results ?? []).compactMap { observation -> OCRTextLine? in
                guard let text = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                let pixels = CGRect(x: box.minX * CGFloat(image.width), y: box.minY * CGFloat(image.height), width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height))
                return OCRTextLine(text: OCRShortcutSymbols.repair(text, bounds: box, image: image), bounds: pixels)
            }
            return OCRTextLayout.assemble(lines, mode: mode)
        }
    }
}
