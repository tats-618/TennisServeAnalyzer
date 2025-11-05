//
//  YOLOBallDetector.swift
//  TennisServeAnalyzer
//
//  YOLOv8n-based tennis ball detection with color filtering
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
    private let confidenceThreshold: Float = 0.5  // 50%以上の信頼度（精度重視）
    private let sportsballClassIndex: Int = 32    // COCO dataset: "sports ball"
    
    // Performance tracking
    private var lastDetectionTime: CFTimeInterval = 0
    private var averageInferenceTime: Double = 0.0
    private var detectionCount: Int = 0
    
    // MARK: - Initialization
    init() {
        setupModel()
    }
    
    private func setupModel() {
        do {
            // Try multiple ways to find the model
            var modelURL: URL?
            
            // Method 1: mlpackage
            modelURL = Bundle.main.url(forResource: "yolov8n", withExtension: "mlpackage")
            
            // Method 2: Compiled model (mlmodelc)
            if modelURL == nil {
                modelURL = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc")
            }
            
            // Method 3: No extension
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
        
        // Create Vision request
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        
        // Perform detection
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )
        
        do {
            try handler.perform([request])
            
            // Process results with color filtering
            if let detection = processResultsWithColorFilter(
                request.results,
                pixelBuffer: pixelBuffer,
                imageSize: CGSize(
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer)
                ),
                timestamp: timestamp
            ) {
                // Update performance metrics
                let inferenceTime = CACurrentMediaTime() - startTime
                updatePerformanceMetrics(inferenceTime: inferenceTime)
                
                return detection
            }
            
        } catch {
            print("❌ Failed to perform detection: \(error)")
        }
        
        return nil
    }
    
    // MARK: - Helper: Circularity Score
    private func calculateCircularity(_ rect: CGRect) -> Double {
        let aspectRatio = rect.width / rect.height
        // Perfect circle = 1.0, elongated = closer to 0
        return 1.0 - abs(1.0 - Double(aspectRatio))
    }
    
    // MARK: - Result Processing with Color Filter
    private func processResultsWithColorFilter(
        _ results: [Any]?,
        pixelBuffer: CVPixelBuffer,
        imageSize: CGSize,
        timestamp: Double
    ) -> BallDetection? {
        guard let results = results as? [VNRecognizedObjectObservation] else {
            return nil
        }
        
        // Filter for sports balls
        var ballCandidates: [(observation: VNRecognizedObjectObservation, rect: CGRect)] = []
        
        for observation in results {
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
            
            // Size filtering: Tennis ball should be 15-120 pixels in radius
            let radius = min(rect.width, rect.height) / 2.0
            guard radius >= 15.0 && radius <= 120.0 else {
                continue
            }
            
            // Aspect ratio filtering: should be roughly circular (0.7-1.3)
            let aspectRatio = rect.width / rect.height
            guard aspectRatio >= 0.7 && aspectRatio <= 1.3 else {
                continue
            }
            
            // Color filtering
            if !verifyTennisBallColor(in: pixelBuffer, boundingBox: rect) {
                print("⚠️ Rejected: not yellow enough")
                continue
            }
            
            ballCandidates.append((observation, rect))
        }
        
        guard !ballCandidates.isEmpty else {
            return nil
        }
        
        // Select best candidate based on confidence and circularity
        let best = ballCandidates.max { a, b in
            let scoreA = a.observation.confidence * Float(calculateCircularity(a.rect))
            let scoreB = b.observation.confidence * Float(calculateCircularity(b.rect))
            return scoreA < scoreB
        }!
        
        let rect = best.rect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2.0
        
        return BallDetection(
            position: center,
            radius: radius,
            confidence: best.observation.confidence,
            timestamp: timestamp
        )
    }
    
    // MARK: - Color Filtering
    private func verifyTennisBallColor(
        in pixelBuffer: CVPixelBuffer,
        boundingBox: CGRect
    ) -> Bool {
        // Lock pixel buffer
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return false
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Sample center region of bounding box
        let centerX = Int(boundingBox.midX)
        let centerY = Int(boundingBox.midY)
        let sampleRadius = Int(min(boundingBox.width, boundingBox.height) / 4)
        
        var yellowPixelCount = 0
        var totalPixelCount = 0
        
        // Sample pixels in center region
        for dy in -sampleRadius...sampleRadius {
            for dx in -sampleRadius...sampleRadius {
                let x = centerX + dx
                let y = centerY + dy
                
                guard x >= 0 && x < width && y >= 0 && y < height else { continue }
                guard dx * dx + dy * dy <= sampleRadius * sampleRadius else { continue }
                
                // Get pixel (assuming BGRA format)
                let pixelOffset = y * bytesPerRow + x * 4
                let pixel = baseAddress.advanced(by: pixelOffset)
                
                let b = pixel.load(fromByteOffset: 0, as: UInt8.self)
                let g = pixel.load(fromByteOffset: 1, as: UInt8.self)
                let r = pixel.load(fromByteOffset: 2, as: UInt8.self)
                
                // Check if yellow/yellow-green
                // Tennis ball: high R & G, low B
                let isYellow = (r > 150 && g > 150 && b < 120) ||
                               (r > 120 && g > 150 && b < 100)
                
                if isYellow {
                    yellowPixelCount += 1
                }
                totalPixelCount += 1
            }
        }
        
        let yellowRatio = Double(yellowPixelCount) / Double(max(totalPixelCount, 1))
        
        // At least 30% of sampled pixels should be yellow
        return yellowRatio >= 0.3
    }
    
    // MARK: - Performance Tracking
    private func updatePerformanceMetrics(inferenceTime: Double) {
        detectionCount += 1
        
        // Exponential moving average
        if averageInferenceTime == 0 {
            averageInferenceTime = inferenceTime
        } else {
            averageInferenceTime = averageInferenceTime * 0.9 + inferenceTime * 0.1
        }
        
        // Log every 30 frames
        if detectionCount % 30 == 0 {
            let fps = 1.0 / averageInferenceTime
            print("🎾 YOLO Detection: \(String(format: "%.1f", fps)) fps (avg: \(String(format: "%.1f", averageInferenceTime * 1000))ms)")
        }
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
        print("🔄 YOLOBallDetector reset")
    }
}
