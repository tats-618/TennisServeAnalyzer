//なう
//  YOLOBallDetector.swift (FINAL OPTIMIZED VERSION)
//  TennisServeAnalyzer
//
//  ✅ OPTIMIZATIONS:
//  - Position filter: 0.04 → 0.10 (relaxed)
//  - High confidence: 0.75 (fine-tuned model)
//  - Color filter: DISABLED (fine-tuned model doesn't need it)
//

import Foundation
import CoreML
import Vision
import CoreMedia
import CoreGraphics
import UIKit

private struct DetectionCandidate {
    let position: CGPoint
    let radius: CGFloat
    let confidence: Float
    let timestamp: Double
}

class YOLOBallDetector {

    // MARK: - Model & switches
    private var visionModel: VNCoreMLModel?
    private var usingFineTuned: Bool = false
    private let sequenceHandler = VNSequenceRequestHandler()

    // Thresholds
    private var highConfidence: Float = 0.80
    private var lowConfidence:  Float = 0.55
    private let confBypassColor: Float = 0.90

    // ✅ OPTIMIZED: Relaxed position filter
    private let excludeBottomRatio: CGFloat = 0.10  // 0.04 → 0.10
    
    // Filters
    private let minRadius: CGFloat = 3.0
    private let maxRadius: CGFloat = 35.0

    private let enableBrightnessFilter = true
    private let maxAverageBrightness: Double = 220.0

    // Color filter (FT model doesn't need it)
    private var enableColorFilter: Bool = false

    // Motion filter
    private var recentDetections: [DetectionCandidate] = []
    private let motionHistorySize: Int = 10
    private let minMotionThreshold: CGFloat = 3.0
    private let maxStationaryFrames: Int = 40

    // Perf
    private var averageInferenceTime: Double = 0.0
    private var detectionCount: Int = 0

    // Debug counters
    private var totalCandidates: Int = 0
    private var rejectedBySize: Int = 0
    private var rejectedByAspect: Int = 0
    private var rejectedByPosition: Int = 0
    private var rejectedByBrightness: Int = 0
    private var rejectedByColor: Int = 0
    private var rejectedByMotion: Int = 0
    private var acceptedDetections: Int = 0

    // Class name
    private let ballClassIdentifier: String = "ball"

    // MARK: - Init
    init() { setupModel() }

    private func setupModel() {
        do {
            var url: URL?
            // 1) fine-tuned
            url = Bundle.main.url(forResource: "best", withExtension: "mlmodelc")
                 ?? Bundle.main.url(forResource: "best", withExtension: "mlpackage")
            // 2) fallback
            if url == nil {
                url = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc")
                     ?? Bundle.main.url(forResource: "yolov8n", withExtension: "mlpackage")
            }
            guard let finalURL = url else {
                print("❌ No CoreML model found in bundle")
                return
            }

            let mlModel = try MLModel(contentsOf: finalURL)
            visionModel = try VNCoreMLModel(for: mlModel)

            let name = finalURL.lastPathComponent
            usingFineTuned = name.contains("best")
            print("✅ Model loaded: \(name)")

            if usingFineTuned {
                // FT settings
                highConfidence = 0.75
                lowConfidence  = 0.55
                enableColorFilter = false
                print("🎾 Fine-tuned model active")
            } else {
                // Default settings
                highConfidence = 0.65
                lowConfidence  = 0.50
                enableColorFilter = true
            }

            print("🏟 Detection thresholds: high=\(highConfidence), low=\(lowConfidence)")
            print("   Size=\(Int(minRadius))–\(Int(maxRadius))px, Bright<\(Int(maxAverageBrightness))")
            print("   Position: exclude bottom \(Int(excludeBottomRatio * 100))%")
            print("   Color filter: \(enableColorFilter ? "ENABLED" : "DISABLED") (auto by model)")
        } catch {
            print("❌ Failed to load model: \(error)")
        }
    }

    // MARK: - API
    func detectBall(from sampleBuffer: CMSampleBuffer, timestamp: Double) -> BallDetection? {
        guard let model = visionModel else { return nil }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let start = CACurrentMediaTime()

        let req = VNCoreMLRequest(model: model)
        req.imageCropAndScaleOption = .scaleFit

        let oriNum = CMGetAttachment(sampleBuffer, key: kCGImagePropertyOrientation, attachmentModeOut: nil) as? NSNumber
        let cgOrientation = oriNum.flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .right

        do {
            try sequenceHandler.perform(
                [req],
                on: pixelBuffer,
                orientation: cgOrientation
            )
            
            if let det = processResults(
                req.results,
                pixelBuffer: pixelBuffer,
                imageSize: CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)),
                timestamp: timestamp
            ) {
                let t = CACurrentMediaTime() - start
                updatePerformanceMetrics(inferenceTime: t)
                return det
            }
        } catch {
            print("❌ Failed to perform detection: \(error)")
        }
        return nil
    }

    // MARK: - Post-process
    private func processResults(
        _ results: [Any]?,
        pixelBuffer: CVPixelBuffer,
        imageSize: CGSize,
        timestamp: Double
    ) -> BallDetection? {

        guard let results = results as? [VNRecognizedObjectObservation] else { return nil }
        var candidates: [(obs: VNRecognizedObjectObservation, rect: CGRect, score: Float)] = []

        for obs in results {
            totalCandidates += 1

            // Class check ("ball" or "0")
            let isBall = obs.labels.contains { l in
                let id = l.identifier.lowercased()
                return id == ballClassIdentifier || id == "0"
            }
            guard isBall else { continue }

            let conf = obs.confidence
            guard conf >= highConfidence else { continue }

            // Rect (Vision coordinates: origin bottom-left)
            let rect = VNImageRectForNormalizedRect(obs.boundingBox, Int(imageSize.width), Int(imageSize.height))
            let r = min(rect.width, rect.height) / 2.0

            // Size
            if r < minRadius || r > maxRadius {
                rejectedBySize += 1
                if r > maxRadius && detectionCount % 30 == 0 {
                    print("🚫 Rejected LARGE: r=\(Int(r))px (likely light)")
                }
                continue
            }

            // Aspect
            let asp = rect.width / rect.height
            if asp < 0.3 || asp > 3.5 {
                rejectedByAspect += 1
                continue
            }

            // ✅ OPTIMIZED: Position filter (relaxed)
            let centerY = rect.midY
            let bottomBoundary = imageSize.height * (1.0 - excludeBottomRatio)
            
            if centerY > bottomBoundary {
                rejectedByPosition += 1
                // Debug log (less frequent)
                if detectionCount % 30 == 0 {
                    print("🚫 Pos reject: y=\(Int(centerY)) > \(Int(bottomBoundary)) (h=\(Int(imageSize.height)))")
                }
                continue
            }

            // Brightness
            if enableBrightnessFilter {
                let avgB = calculateAverageBrightness(in: pixelBuffer, boundingBox: rect)
                if avgB > maxAverageBrightness {
                    rejectedByBrightness += 1
                    if detectionCount % 30 == 0 {
                        print("💡 Rejected BRIGHT: brightness=\(Int(avgB))")
                    }
                    continue
                }
            }

            // Color (FT model: disabled. High confidence: bypassed)
            if enableColorFilter && conf < confBypassColor {
                if !passesColorHeuristic(in: pixelBuffer, rect: rect) {
                    rejectedByColor += 1
                    continue
                }
            }

            // Motion
            let centerImageSpace = CGPoint(x: rect.midX, y: rect.midY)
            if !hasSignificantMotionOrNew(position: centerImageSpace, radius: r, timestamp: timestamp) {
                rejectedByMotion += 1
                continue
            }

            acceptedDetections += 1
            if detectionCount % 15 == 0 {
                print("✅ Ball: conf=\(String(format: "%.2f", conf)), r=\(Int(r))px, y=\(Int(centerY))")
            }
            candidates.append((obs, rect, conf))
        }

        // Debug summary
        if detectionCount % 60 == 0 && totalCandidates > 0 {
            let rate = totalCandidates > 0 ? Double(acceptedDetections) / Double(totalCandidates) * 100.0 : 0.0
            print("📊 Last ~60 frames:")
            print("   Total: \(totalCandidates)")
            print("   ❌ Size: \(rejectedBySize), Aspect: \(rejectedByAspect), Pos: \(rejectedByPosition)")
            print("   ❌ Bright: \(rejectedByBrightness), Color: \(rejectedByColor), Motion: \(rejectedByMotion)")
            print("   ✅ Accepted: \(acceptedDetections) (\(String(format: "%.1f", rate))%)")
            totalCandidates = 0; rejectedBySize = 0; rejectedByAspect = 0; rejectedByPosition = 0
            rejectedByBrightness = 0; rejectedByColor = 0; rejectedByMotion = 0; acceptedDetections = 0
        }

        guard let best = candidates.min(by: { $0.rect.midY < $1.rect.midY }) else { return nil }

        // Convert to UI coordinates (origin: top-left)
        let rect = best.rect
        let centerImageSpace = CGPoint(x: rect.midX, y: rect.midY)  // Vision (bottom-left)
        let uiCenter = CGPoint(x: centerImageSpace.x,
                               y: imageSize.height - centerImageSpace.y)  // UI (top-left)
        let radius = min(rect.width, rect.height) / 2.0

        // Motion history: use image space coordinates
        addToMotionHistory(position: centerImageSpace, radius: radius, confidence: best.score, timestamp: timestamp)

        return BallDetection(
            position: uiCenter,
            radius: radius,
            confidence: best.score,
            timestamp: timestamp,
            imageSize: imageSize
        )
    }

    // MARK: - Color heuristic (gate-controlled, very lenient)
    private func passesColorHeuristic(in pixelBuffer: CVPixelBuffer, rect: CGRect) -> Bool {
        // Very lenient to avoid false negatives
        return true
    }

    // MARK: - Brightness
    private func calculateAverageBrightness(in pixelBuffer: CVPixelBuffer, boundingBox: CGRect) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0.0 }

        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        let cx = Int(boundingBox.midX)
        let cy = Int(boundingBox.midY)
        let sr = max(3, Int(min(boundingBox.width, boundingBox.height) / 4))

        var total: Double = 0.0
        var count: Int = 0

        for dy in -sr...sr {
            for dx in -sr...sr {
                let x = cx + dx, y = cy + dy
                guard x >= 0 && x < w && y >= 0 && y < h else { continue }
                guard dx*dx + dy*dy <= sr*sr else { continue }

                let off = y * bpr + x * 4
                let p = base.advanced(by: off)

                let b = Double(p.load(fromByteOffset: 0, as: UInt8.self))
                let g = Double(p.load(fromByteOffset: 1, as: UInt8.self))
                let r = Double(p.load(fromByteOffset: 2, as: UInt8.self))
                let yVal = 0.2126 * r + 0.7152 * g + 0.0722 * b

                total += yVal
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0.0
    }

    // MARK: - Motion
    private func hasSignificantMotionOrNew(position: CGPoint, radius: CGFloat, timestamp: Double) -> Bool {
        recentDetections = recentDetections.filter { timestamp - $0.timestamp < 0.5 }
        guard recentDetections.count >= 3 else { return true }

        let similar = recentDetections.filter { past in
            let dx = position.x - past.position.x
            let dy = position.y - past.position.y
            let dist = sqrt(dx*dx + dy*dy)
            let sizeMatch = abs(radius - past.radius) < 15.0
            return dist < 40.0 && sizeMatch
        }

        guard similar.count >= 3 else { return true }

        let xs = similar.map { $0.position.x }
        let ys = similar.map { $0.position.y }
        let xr = (xs.max() ?? position.x) - (xs.min() ?? position.x)
        let yr = (ys.max() ?? position.y) - (ys.min() ?? position.y)
        let total = sqrt(xr*xr + yr*yr)

        if similar.count > maxStationaryFrames && total < minMotionThreshold { return false }
        return true
    }

    private func addToMotionHistory(position: CGPoint, radius: CGFloat, confidence: Float, timestamp: Double) {
        let c = DetectionCandidate(position: position, radius: radius, confidence: confidence, timestamp: timestamp)
        recentDetections.append(c)
        if recentDetections.count > 100 { recentDetections.removeFirst(recentDetections.count - 100) }
    }

    // MARK: - Perf
    private func updatePerformanceMetrics(inferenceTime: Double) {
        detectionCount += 1
        if averageInferenceTime == 0 {
            averageInferenceTime = inferenceTime
        } else {
            averageInferenceTime = averageInferenceTime * 0.9 + inferenceTime * 0.1
        }
        if detectionCount % 120 == 0 {
            let fps = 1.0 / max(averageInferenceTime, 1e-6)
            print("🎾 YOLO (FINE-TUNED): \(String(format: "%.1f", fps)) fps (\(String(format: "%.1f", averageInferenceTime * 1000))ms)")
        }
    }

    // MARK: - Utils
    func getPerformanceInfo() -> (fps: Double, avgMs: Double) {
        let fps = averageInferenceTime > 0 ? 1.0 / averageInferenceTime : 0.0
        return (fps, averageInferenceTime * 1000.0)
    }

    func reset() {
        detectionCount = 0
        averageInferenceTime = 0.0
        totalCandidates = 0
        rejectedBySize = 0
        rejectedByAspect = 0
        rejectedByPosition = 0
        rejectedByBrightness = 0
        rejectedByColor = 0
        rejectedByMotion = 0
        acceptedDetections = 0
        recentDetections.removeAll()
        print("🔄 YOLOBallDetector reset")
    }
}
