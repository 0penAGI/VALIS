import Foundation
import UIKit
import CoreML
@preconcurrency import Vision

struct SimilarImageMatch: Sendable {
    let filename: String
    let distance: Float
}

struct VisionAttachmentAnalysis: Sendable {
    let attachment: MessageImageAttachment
    let ocrText: String?
    let captionText: String?
    let faceCount: Int
    let faceLandmarkTags: [String]
    let detectedObjects: [String]
    let customTags: [String]
    let similarImages: [SimilarImageMatch]
    let notes: [String]

    var contextBlock: String {
        var lines: [String] = []
        lines.append("[Image attachment analysis]")
        lines.append("filename: \(attachment.filename)")
        lines.append("dimensions: \(attachment.pixelWidth)x\(attachment.pixelHeight)")

        if let captionText, !captionText.isEmpty {
            lines.append("caption: \(captionText)")
        }

        lines.append("face_count: \(faceCount)")
        if !faceLandmarkTags.isEmpty {
            lines.append("face_landmarks: \(faceLandmarkTags.joined(separator: ", "))")
        }

        if !detectedObjects.isEmpty {
            lines.append("detected_objects: \(detectedObjects.joined(separator: ", "))")
        }

        if !customTags.isEmpty {
            lines.append("custom_visual_tags: \(customTags.joined(separator: ", "))")
        }

        if let ocrText, !ocrText.isEmpty {
            lines.append("ocr_text:")
            lines.append(ocrText)
        } else {
            lines.append("ocr_text: none")
        }

        if !similarImages.isEmpty {
            let formatted = similarImages.map { "\($0.filename) (distance: \(String(format: "%.3f", $0.distance)))" }
            lines.append("similar_local_images: \(formatted.joined(separator: ", "))")
        }

        if !notes.isEmpty {
            lines.append("notes: \(notes.joined(separator: " | "))")
        }

        lines.append("Use only this analysis. Do not invent unseen visual details.")
        return lines.joined(separator: "\n")
    }
}

final class VisionAttachmentService {
    static let shared = VisionAttachmentService()
    private let objectModelNames = ["VisionObjectDetector", "TinyYOLOv8n", "MobileNetSSD"]

    private init() {}

    func analyze(_ attachment: MessageImageAttachment) async -> VisionAttachmentAnalysis {
        let motivators = MotivationService.shared.state
        return await Task.detached(priority: .userInitiated) {
            self.analyzeSync(attachment, motivators: motivators)
        }.value
    }

    private func analyzeSync(_ attachment: MessageImageAttachment, motivators: MotivatorState) -> VisionAttachmentAnalysis {
        let imageURL = attachmentURL(for: attachment)
        guard let image = UIImage(contentsOfFile: imageURL.path),
              let cgImage = image.cgImage else {
            return VisionAttachmentAnalysis(
                attachment: attachment,
                ocrText: nil,
                captionText: nil,
                faceCount: 0,
                faceLandmarkTags: [],
                detectedObjects: [],
                customTags: [],
                similarImages: [],
                notes: ["image file could not be loaded"]
            )
        }

        let ocrText = recognizeText(in: cgImage)
        let faceObservations = detectFaces(in: cgImage)
        let faceCount = faceObservations.count
        let faceLandmarkTags = detectFaceLandmarkTags(in: cgImage)
        let detectedObjects = detectObjects(in: cgImage)
        let customTags = buildCustomTags(
            image: image,
            ocrText: ocrText,
            faceCount: faceCount,
            faceLandmarkTags: faceLandmarkTags,
            detectedObjects: detectedObjects
        )
        let captionText = buildCaption(
            from: customTags,
            faceCount: faceCount,
            ocrText: ocrText,
            detectedObjects: detectedObjects
        )
        let similarImages = findSimilarImages(to: attachment, using: cgImage, motivators: motivators)

        var notes = [
            "custom visual layer active",
            "similarity search uses local feature prints"
        ]
        if detectedObjects.isEmpty {
            notes.append("object model unavailable or found no confident detections")
        }
        if faceCount > 0 && faceLandmarkTags.isEmpty {
            notes.append("face rectangles found without confident landmarks")
        }

        return VisionAttachmentAnalysis(
            attachment: attachment,
            ocrText: ocrText,
            captionText: captionText,
            faceCount: faceCount,
            faceLandmarkTags: faceLandmarkTags,
            detectedObjects: detectedObjects,
            customTags: customTags,
            similarImages: similarImages,
            notes: notes
        )
    }

    private func recognizeText(in cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "ru-RU"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            let lines = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        } catch {
            return nil
        }
    }

    private func detectFaces(in cgImage: CGImage) -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            return request.results ?? []
        } catch {
            return []
        }
    }

    private func detectFaceLandmarkTags(in cgImage: CGImage) -> [String] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            guard !observations.isEmpty else { return [] }

            var tags = Set<String>()
            for observation in observations {
                guard let landmarks = observation.landmarks else { continue }
                if landmarks.leftEye != nil || landmarks.rightEye != nil { tags.insert("eyes") }
                if landmarks.nose != nil { tags.insert("nose") }
                if landmarks.outerLips != nil || landmarks.innerLips != nil { tags.insert("lips") }
                if landmarks.faceContour != nil { tags.insert("face-contour") }
                if landmarks.leftEyebrow != nil || landmarks.rightEyebrow != nil { tags.insert("eyebrows") }
            }
            return tags.sorted()
        } catch {
            return []
        }
    }

    private func detectObjects(in cgImage: CGImage) -> [String] {
        guard let model = loadObjectModel() else { return [] }

        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let observations = (request.results as? [VNRecognizedObjectObservation]) ?? []
            let labels = observations
                .filter { ($0.labels.first?.confidence ?? 0) >= 0.35 }
                .compactMap { observation in
                    observation.labels.first.map { "\($0.identifier) (\(Int($0.confidence * 100))%)" }
                }
            return Array(labels.prefix(6))
        } catch {
            return []
        }
    }

    private func loadObjectModel() -> VNCoreMLModel? {
        for name in objectModelNames {
            if let compiledURL = Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
               let model = try? MLModel(contentsOf: compiledURL),
               let vnModel = try? VNCoreMLModel(for: model) {
                return vnModel
            }
        }
        return nil
    }

    private func featurePrint(for cgImage: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        } catch {
            return nil
        }
    }

    private func findSimilarImages(
        to attachment: MessageImageAttachment,
        using cgImage: CGImage,
        motivators: MotivatorState
    ) -> [SimilarImageMatch] {
        guard let basePrint = featurePrint(for: cgImage) else { return [] }

        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: attachmentsDirectoryURL,
            includingPropertiesForKeys: nil
        )) ?? []

        var candidates: [QuantumMemoryService.ImageCandidate] = []

        for fileURL in fileURLs {
            guard fileURL.lastPathComponent != attachment.filename else { continue }
            guard let image = UIImage(contentsOfFile: fileURL.path),
                  let compareCGImage = image.cgImage,
                  let comparePrint = featurePrint(for: compareCGImage) else { continue }

            var distance: Float = 0
            do {
                try basePrint.computeDistance(&distance, to: comparePrint)
                if distance < 18 {
                    let score = max(0.0001, 1.0 / Double(distance + 0.35))
                    candidates.append(
                        QuantumMemoryService.ImageCandidate(
                            filename: fileURL.lastPathComponent,
                            distance: Double(distance),
                            score: score,
                            isPinnedLike: false
                        )
                    )
                }
            } catch {
                continue
            }
        }

        guard !candidates.isEmpty else { return [] }
        let matchCount = max(3, min(5, Int(round(3 + (motivators.curiosity * 2.0)))))
        let selected = QuantumMemoryService.collapseImageMatches(
            candidates: candidates,
            k: matchCount,
            motivators: motivators
        )

        return selected.map {
            SimilarImageMatch(
                filename: $0.filename,
                distance: $0.distance
            )
        }
    }

    private func buildCustomTags(
        image: UIImage,
        ocrText: String?,
        faceCount: Int,
        faceLandmarkTags: [String],
        detectedObjects: [String]
    ) -> [String] {
        var tags: [String] = []

        let aspectRatio = image.size.width / max(1, image.size.height)
        if aspectRatio > 1.35 {
            tags.append("landscape-layout")
        } else if aspectRatio < 0.8 {
            tags.append("portrait-layout")
        } else {
            tags.append("square-ish-layout")
        }

        let brightness = estimateBrightness(image)
        if brightness > 0.72 {
            tags.append("bright-scene")
        } else if brightness < 0.35 {
            tags.append("dark-scene")
        } else {
            tags.append("balanced-light")
        }

        if let ocrText, !ocrText.isEmpty {
            tags.append("contains-text")
            if ocrText.count > 120 {
                tags.append("text-heavy")
            }
        }

        if faceCount > 0 {
            tags.append(faceCount == 1 ? "single-face" : "multiple-faces")
        }

        if !faceLandmarkTags.isEmpty {
            tags.append("landmarks-present")
        }

        if !detectedObjects.isEmpty {
            tags.append("object-model-hit")
        }

        let colorMood = estimateColorMood(image)
        tags.append(colorMood)

        return tags
    }

    private func buildCaption(from tags: [String], faceCount: Int, ocrText: String?, detectedObjects: [String]) -> String? {
        var parts: [String] = []
        if tags.contains("contains-text") {
            parts.append("image with visible text")
        }
        if faceCount > 0 {
            parts.append(faceCount == 1 ? "one visible face" : "\(faceCount) visible faces")
        }
        if let firstObject = detectedObjects.first {
            parts.append("object cue: \(firstObject)")
        }
        if let mood = tags.first(where: { $0.hasSuffix("-dominant") || $0 == "neutral-color-balance" }) {
            parts.append(mood.replacingOccurrences(of: "-", with: " "))
        }
        if let layout = tags.first(where: { $0.contains("layout") }) {
            parts.append(layout.replacingOccurrences(of: "-", with: " "))
        }

        let caption = parts.joined(separator: ", ").trimmingCharacters(in: .whitespacesAndNewlines)
        return caption.isEmpty ? nil : caption
    }

    private func estimateBrightness(_ image: UIImage) -> CGFloat {
        guard let cgImage = image.cgImage else { return 0.5 }
        guard let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return 0.5 }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = max(4, cgImage.bitsPerPixel / 8)
        let sampleStep = max(1, min(width, height) / 24)

        var total: CGFloat = 0
        var count: CGFloat = 0

        for y in stride(from: 0, to: height, by: sampleStep) {
            for x in stride(from: 0, to: width, by: sampleStep) {
                let offset = (y * cgImage.bytesPerRow) + (x * bytesPerPixel)
                let r = CGFloat(ptr[offset]) / 255
                let g = CGFloat(ptr[offset + 1]) / 255
                let b = CGFloat(ptr[offset + 2]) / 255
                total += (0.299 * r) + (0.587 * g) + (0.114 * b)
                count += 1
            }
        }

        guard count > 0 else { return 0.5 }
        return total / count
    }

    private func estimateColorMood(_ image: UIImage) -> String {
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return "neutral-color-balance" }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = max(4, cgImage.bitsPerPixel / 8)
        let sampleStep = max(1, min(width, height) / 24)

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var count: CGFloat = 0

        for y in stride(from: 0, to: height, by: sampleStep) {
            for x in stride(from: 0, to: width, by: sampleStep) {
                let offset = (y * cgImage.bytesPerRow) + (x * bytesPerPixel)
                red += CGFloat(ptr[offset]) / 255
                green += CGFloat(ptr[offset + 1]) / 255
                blue += CGFloat(ptr[offset + 2]) / 255
                count += 1
            }
        }

        guard count > 0 else { return "neutral-color-balance" }
        red /= count
        green /= count
        blue /= count

        let maxValue = max(red, max(green, blue))
        let minValue = min(red, min(green, blue))
        if maxValue - minValue < 0.08 {
            return "neutral-color-balance"
        }
        if maxValue == red { return "red-dominant" }
        if maxValue == green { return "green-dominant" }
        return "blue-dominant"
    }

    private var attachmentsDirectoryURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("image-attachments", isDirectory: true)
    }

    private func attachmentURL(for attachment: MessageImageAttachment) -> URL {
        attachmentsDirectoryURL.appendingPathComponent(attachment.filename)
    }
}
