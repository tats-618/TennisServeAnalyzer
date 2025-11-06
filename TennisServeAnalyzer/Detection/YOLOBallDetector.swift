//
//  YOLOBallDetector.swift
//  TennisServeAnalyzer
//
//  YOLOv8n-based tennis ball detection with SMART filtering
//  - Position filter (exclude ceiling area)
//  - Brightness filter (exclude lights)
//  - Relaxed color filter
//

import Foundation
import CoreML
import Vision
import CoreMedia
import CoreGraphics
import UIKit

// MARK: - YOLO Ball Detector
class YOLOBallDetector {
    
    // MARK: Properties
    private var visionModel: VNCoreMLModel?
    
    // 🔧 Detection thresholds
    private let confidenceThreshold: Float = 0.3
    private let sportsballClassIndex: Int = 32
    
    // 🔧 Spatial filtering
    private let excludeTopRatio: CGFloat = 0.20  // Exclude top 20% (ceiling)
    private let excludeBottomRatio: CGFloat = 0.05  // Exclude bottom 5% (floor)
    
    // 🔧 Brightness filtering (to reject lights)
    private let maxAverageBrightness: Double = 200.0  // 0-255 scale
    
    // Performance tracking
    private var averageInferenceTime: Double = 0.0
    private var detectionCount: Int = 0
    
    // 📊 Debug statistics
    private var totalCandidates: Int = 0
    private var rejectedBySize: Int = 0
    private var rejectedByAspect: Int = 0
    private var rejectedByPosition: Int = 0
    private var rejectedByBrightness: Int = 0
    private var rejectedByColor: Int = 0
    private var acceptedDetections: Int = 0
    
    // MARK: - Initialization
    init() {
        setupModel()
    }
    
    private func setupModel() {
        do {
            var modelURL: URL?
            
            modelURL = Bundle.main.url(forResource: "yolov8n", withExtension: "mlpackage")
            
            if modelURL == nil {
                modelURL = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc")
            }
            
            if modelURL == nil {
                modelURL = Bundle.main.url(forResource: "yolov8n", withExtension: nil)
            }
            
            guard let finalURL = modelURL else {
                print("❌ YOLOv8n model not found in bundle")
                return
            }
            
            let mlModel = try MLModel(contentsOf: finalURL)
            visionModel = try VNCoreMLModel(for: mlModel)
            
            print("✅ YOLOv8n model loaded successfully")
            print("🔧 Smart filtering enabled:")
            print("   - Confidence: ≥\(confidenceThreshold)")
            print("   - Size: 5-150px radius")
            print("   - Position: exclude top \(Int(excludeTopRatio*100))% (ceiling)")
            print("   - Brightness: <\(Int(maxAverageBrightness)) (reject lights)")
            print("   - Color: relaxed tennis ball tones")
            
        } catch {
            print("❌ Failed to load YOLOv8n model: \(error)")
        }
    }
    
    // MARK: - Main Detection Method
    func detectBall(
        from sampleBuffer: CMSampleBuffer,
        timestamp: Double
    ) -> BallDetection? {
        guard let model = visionModel else {
            return nil
        }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        
        let startTime = CACurrentMediaTime()
        
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )
        
        do {
            try handler.perform([request])
            
            if let detection = processResults(
                request.results,
                pixelBuffer: pixelBuffer,
                imageSize: CGSize(
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer)
                ),
                timestamp: timestamp
            ) {
                let inferenceTime = CACurrentMediaTime() - startTime
                updatePerformanceMetrics(inferenceTime: inferenceTime)
                return detection
            }
            
        } catch {
            print("❌ Failed to perform detection: \(error)")
        }
        
        return nil
    }
    
    // MARK: - Result Processing with SMART Filtering
    private func processResults(
        _ results: [Any]?,
        pixelBuffer: CVPixelBuffer,
        imageSize: CGSize,
        timestamp: Double
    ) -> BallDetection? {
        guard let results = results as? [VNRecognizedObjectObservation] else {
            return nil
        }
        
        var ballCandidates: [(observation: VNRecognizedObjectObservation, rect: CGRect, score: Float)] = []
        
        for observation in results {
            totalCandidates += 1
            
            let hasSportsBall = observation.labels.contains { label in
                let id = label.identifier.lowercased()
                return id.contains("sports") ||
                       id.contains("ball") ||
                       id.contains("tennis") ||
                       id == "\(sportsballClassIndex)" ||
                       id == "32"
            }
            
            guard hasSportsBall && observation.confidence >= confidenceThreshold else {
                continue
            }
            
            let boundingBox = observation.boundingBox
            let rect = VNImageRectForNormalizedRect(
                boundingBox,
                Int(imageSize.width),
                Int(imageSize.height)
            )
            
            // 🔧 FILTER 1: Size (5-150px radius)
            let radius = min(rect.width, rect.height) / 2.0
            if radius < 5.0 || radius > 150.0 {
                rejectedBySize += 1
                continue
            }
            
            // 🔧 FILTER 2: Aspect ratio (0.4-2.5)
            let aspectRatio = rect.width / rect.height
            if aspectRatio < 0.4 || aspectRatio > 2.5 {
                rejectedByAspect += 1
                continue
            }
            
            // 🔧 FILTER 3: Position (exclude ceiling and floor)
            let centerY = rect.midY
            let topBoundary = imageSize.height * excludeTopRatio
            let bottomBoundary = imageSize.height * (1.0 - excludeBottomRatio)
            
            if centerY < topBoundary || centerY > bottomBoundary {
                rejectedByPosition += 1
                if detectionCount % 120 == 0 {
                    print("🚫 Rejected ceiling/floor: y=\(Int(centerY)) (valid: \(Int(topBoundary))-\(Int(bottomBoundary)))")
                }
                continue
            }
            
            // 🔧 FILTER 4: Brightness (reject lights)
            let avgBrightness = calculateAverageBrightness(
                in: pixelBuffer,
                boundingBox: rect
            )
            
            if avgBrightness > maxAverageBrightness {
                rejectedByBrightness += 1
                if detectionCount % 120 == 0 {
                    print("💡 Rejected light: brightness=\(Int(avgBrightness)) (max: \(Int(maxAverageBrightness)))")
                }
                continue
            }
            
            // 🔧 FILTER 5: Color (relaxed for tennis ball)
            if observation.confidence < 0.7 {  // Only check low-confidence detections
                if !verifyTennisBallColor(in: pixelBuffer, boundingBox: rect) {
                    rejectedByColor += 1
                    continue
                }
            }
            
            acceptedDetections += 1
            
            // Calculate composite score
            let circularity = Float(1.0 - abs(1.0 - Double(aspectRatio)))
            let compositeScore = observation.confidence * circularity
            
            if detectionCount % 120 == 0 {
                print("✅ Ball: conf=\(String(format: "%.2f", observation.confidence)), r=\(Int(radius))px, y=\(Int(centerY)), bright=\(Int(avgBrightness))")
            }
            
            ballCandidates.append((observation, rect, compositeScore))
        }
        
        // Debug stats every 2 seconds (120 frames at 60fps)
        if detectionCount % 120 == 0 && totalCandidates > 0 {
            printDebugStats()
        }
        
        guard !ballCandidates.isEmpty else {
            return nil
        }
        
        // If multiple candidates, prefer center of frame
        let best: (observation: VNRecognizedObjectObservation, rect: CGRect, score: Float)
        
        if ballCandidates.count > 1 {
            // Sort by distance from center
            let centerX = imageSize.width / 2.0
            let centerY = imageSize.height / 2.0
            
            best = ballCandidates.min { a, b in
                let distA = sqrt(pow(a.rect.midX - centerX, 2) + pow(a.rect.midY - centerY, 2))
                let distB = sqrt(pow(b.rect.midX - centerX, 2) + pow(b.rect.midY - centerY, 2))
                return distA < distB
            }!
            
            if detectionCount % 120 == 0 {
                print("🎯 Multiple balls detected, chose center-most")
            }
        } else {
            best = ballCandidates[0]
        }
        
        let rect = best.rect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2.0
        
        return BallDetection(
            position: center,
            radius: radius,
            confidence: best.observation.confidence,
            timestamp: timestamp,
            imageSize: imageSize
        )
    }
    
    // MARK: - Brightness Calculation
    private func calculateAverageBrightness(
        in pixelBuffer: CVPixelBuffer,
        boundingBox: CGRect
    ) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return 0.0
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        let centerX = Int(boundingBox.midX)
        let centerY = Int(boundingBox.midY)
        let sampleRadius = max(3, Int(min(boundingBox.width, boundingBox.height) / 4))
        
        var totalBrightness: Double = 0.0
        var pixelCount: Int = 0
        
        for dy in -sampleRadius...sampleRadius {
            for dx in -sampleRadius...sampleRadius {
                let x = centerX + dx
                let y = centerY + dy
                
                guard x >= 0 && x < width && y >= 0 && y < height else { continue }
                guard dx * dx + dy * dy <= sampleRadius * sampleRadius else { continue }
                
                let pixelOffset = y * bytesPerRow + x * 4
                let pixel = baseAddress.advanced(by: pixelOffset)
                
                let b = Double(pixel.load(fromByteOffset: 0, as: UInt8.self))
                let g = Double(pixel.load(fromByteOffset: 1, as: UInt8.self))
                let r = Double(pixel.load(fromByteOffset: 2, as: UInt8.self))
                
                // Calculate perceived brightness (ITU-R BT.709)
                let brightness = 0.2126 * r + 0.7152 * g + 0.0722 * b
                
                totalBrightness += brightness
                pixelCount += 1
            }
        }
        
        return pixelCount > 0 ? totalBrightness / Double(pixelCount) : 0.0
    }
    
    // MARK: - Color Verification (Relaxed)
    private func verifyTennisBallColor(
        in pixelBuffer: CVPixelBuffer,
        boundingBox: CGRect
    ) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return false
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        let centerX = Int(boundingBox.midX)
        let centerY = Int(boundingBox.midY)
        let sampleRadius = max(3, Int(min(boundingBox.width, boundingBox.height) / 4))
        
        var validColorCount = 0
        var totalCount = 0
        
        for dy in -sampleRadius...sampleRadius {
            for dx in -sampleRadius...sampleRadius {
                let x = centerX + dx
                let y = centerY + dy
                
                guard x >= 0 && x < width && y >= 0 && y < height else { continue }
                guard dx * dx + dy * dy <= sampleRadius * sampleRadius else { continue }
                
                let pixelOffset = y * bytesPerRow + x * 4
                let pixel = baseAddress.advanced(by: pixelOffset)
                
                let b = Double(pixel.load(fromByteOffset: 0, as: UInt8.self))
                let g = Double(pixel.load(fromByteOffset: 1, as: UInt8.self))
                let r = Double(pixel.load(fromByteOffset: 2, as: UInt8.self))
                
                // Tennis ball: yellow/yellow-green/light tones, NOT white
                // Reject if too bright (white) or too dark
                let avgRG = (r + g) / 2.0
                let brightness = 0.2126 * r + 0.7152 * g + 0.0722 * b
                
                let isValidBallColor =
                    avgRG > b * 1.2 &&  // Warm tone (R+G > B)
                    brightness > 80.0 && brightness < 220.0 &&  // Not too dark or bright
                    r > 70.0 && g > 70.0  // Has color (not gray)
                
                if isValidBallColor {
                    validColorCount += 1
                }
                totalCount += 1
            }
        }
        
        let validRatio = Double(validColorCount) / Double(max(totalCount, 1))
        return validRatio >= 0.15  // 15% threshold
    }
    
    // MARK: - Performance Tracking
    private func updatePerformanceMetrics(inferenceTime: Double) {
        detectionCount += 1
        
        if averageInferenceTime == 0 {
            averageInferenceTime = inferenceTime
        } else {
            averageInferenceTime = averageInferenceTime * 0.9 + inferenceTime * 0.1
        }
        
        if detectionCount % 120 == 0 {
            let fps = 1.0 / averageInferenceTime
            print("🎾 YOLO: \(String(format: "%.1f", fps)) fps (\(String(format: "%.1f", averageInferenceTime * 1000))ms)")
        }
    }
    
    // MARK: - Debug Statistics
    private func printDebugStats() {
        let acceptRate = totalCandidates > 0 ? Double(acceptedDetections) / Double(totalCandidates) * 100.0 : 0.0
        print("📊 Last 120 frames:")
        print("   Total: \(totalCandidates)")
        print("   ❌ Size: \(rejectedBySize), Aspect: \(rejectedByAspect)")
        print("   ❌ Position: \(rejectedByPosition), Brightness: \(rejectedByBrightness), Color: \(rejectedByColor)")
        print("   ✅ Accepted: \(acceptedDetections) (\(String(format: "%.1f", acceptRate))%)")
        
        totalCandidates = 0
        rejectedBySize = 0
        rejectedByAspect = 0
        rejectedByPosition = 0
        rejectedByBrightness = 0
        rejectedByColor = 0
        acceptedDetections = 0
    }
    
    // MARK: - Utility
    func getPerformanceInfo() -> (fps: Double, avgMs: Double) {
        let fps = averageInferenceTime > 0 ? 1.0 / averageInferenceTime : 0.0
        let avgMs = averageInferenceTime * 1000.0
        return (fps, avgMs)
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
        acceptedDetections = 0
        print("🔄 YOLOBallDetector reset")
    }
}
