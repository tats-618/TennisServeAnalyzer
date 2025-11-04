//
//  BallTracker.swift
//  TennisServeAnalyzer
//
//  IMPROVED: Velocity-based apex detection according to research design
//

import CoreImage
import CoreMedia
import UIKit
import Accelerate

// MARK: - Ball Detection Result
struct BallDetection {
    let position: CGPoint  // Screen coordinates
    let radius: CGFloat
    let confidence: Float  // 0.0 - 1.0
    let timestamp: Double
    
    var isValid: Bool {
        return confidence > 0.5 && radius > 5.0 && radius < 100.0
    }
}

// NOTE: BallApex is defined in ServeDataModel.swift (shared)

// MARK: - Kalman Filter State
private struct KalmanState {
    var x: Double = 0.0
    var y: Double = 0.0
    var vx: Double = 0.0
    var vy: Double = 0.0
    var timestamp: Double = 0.0
}

// MARK: - Ball Tracker (IMPROVED)
class BallTracker {
    // MARK: Properties
    private let ciContext: CIContext
    
    // Kalman filter
    private var kalmanState: KalmanState?
    private let processNoise: Double = 10.0
    private let measurementNoise: Double = 5.0
    
    // Detection history
    private var detectionHistory: [BallDetection] = []
    private let maxHistorySize: Int = 120  // ~1s at 120fps
    
    // Configuration
    private let colorRange: (hue: ClosedRange<CGFloat>, saturation: ClosedRange<CGFloat>) = (
        hue: 0.12...0.18,
        saturation: 0.3...1.0
    )
    
    private let sizeRange: ClosedRange<CGFloat> = 8...80
    
    // Apex detection state
    private var lastApexTime: Double = 0.0
    private let apexCooldown: Double = 1.5  // Minimum 1.5s between apex detections
    
    // MARK: - Initialization
    init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: metalDevice)
        } else {
            ciContext = CIContext()
        }
        
        print("🎾 BallTracker initialized (velocity-based apex detection)")
    }
    
    // MARK: - Main Tracking Method
    func trackBall(
        from sampleBuffer: CMSampleBuffer,
        timestamp: Double
    ) -> BallDetection? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Color-based detection
        guard let ballPosition = detectBallByColor(in: ciImage) else {
            return predictBallPosition(timestamp: timestamp)
        }
        
        let detection = BallDetection(
            position: ballPosition.center,
            radius: ballPosition.radius,
            confidence: ballPosition.confidence,
            timestamp: timestamp
        )
        
        // Update Kalman filter
        updateKalmanFilter(with: detection)
        
        // Add to history
        addToHistory(detection)
        
        return detection
    }
    
    // MARK: - Color-Based Detection (Same as before)
    private func detectBallByColor(in image: CIImage) -> (center: CGPoint, radius: CGFloat, confidence: Float)? {
        guard let hsvImage = convertToHSV(image) else {
            return nil
        }
        
        guard let maskedImage = applyColorMask(to: hsvImage) else {
            return nil
        }
        
        return findLargestBlob(in: maskedImage, originalSize: image.extent.size)
    }
    
    private func convertToHSV(_ image: CIImage) -> CIImage? {
        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(image, forKey: kCIInputImageKey)
        return filter?.outputImage
    }
    
    private func applyColorMask(to image: CIImage) -> CIImage? {
        let filter = CIFilter(name: "CIColorThreshold")
        filter?.setValue(image, forKey: kCIInputImageKey)
        
        let targetColor = CIColor(red: 0.8, green: 0.9, blue: 0.1)
        filter?.setValue(targetColor, forKey: "inputColor")
        filter?.setValue(0.3, forKey: "inputThreshold")
        
        return filter?.outputImage
    }
    
    private func findLargestBlob(
        in image: CIImage,
        originalSize: CGSize
    ) -> (center: CGPoint, radius: CGFloat, confidence: Float)? {
        let width = Int(originalSize.width)
        let height = Int(originalSize.height)
        
        var bitmap = [UInt8](repeating: 0, count: width * height)
        
        ciContext.render(
            image,
            toBitmap: &bitmap,
            rowBytes: width,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .L8,
            colorSpace: CGColorSpaceCreateDeviceGray()
        )
        
        return findCircleInBitmap(bitmap, width: width, height: height)
    }
    
    private func findCircleInBitmap(
        _ bitmap: [UInt8],
        width: Int,
        height: Int
    ) -> (center: CGPoint, radius: CGFloat, confidence: Float)? {
        var maxSum: Int = 0
        var bestCenter = CGPoint.zero
        var bestRadius: CGFloat = 0
        
        let stepSize = 10
        let testRadii: [CGFloat] = [10, 15, 20, 25, 30, 40]
        
        for testRadius in testRadii {
            for y in stride(from: Int(testRadius), to: height - Int(testRadius), by: stepSize) {
                for x in stride(from: Int(testRadius), to: width - Int(testRadius), by: stepSize) {
                    let sum = sumInCircle(bitmap, width: width, center: (x, y), radius: Int(testRadius))
                    
                    if sum > maxSum {
                        maxSum = sum
                        bestCenter = CGPoint(x: x, y: y)
                        bestRadius = testRadius
                    }
                }
            }
        }
        
        let maxPossible = Int(Double.pi * bestRadius * bestRadius * 255.0)
        let confidence = maxPossible > 0 ? Float(maxSum) / Float(maxPossible) : 0.0
        
        guard confidence > 0.3 && sizeRange.contains(bestRadius) else {
            return nil
        }
        
        return (center: bestCenter, radius: bestRadius, confidence: confidence)
    }
    
    private func sumInCircle(_ bitmap: [UInt8], width: Int, center: (Int, Int), radius: Int) -> Int {
        var sum = 0
        let r2 = radius * radius
        
        for dy in -radius...radius {
            for dx in -radius...radius {
                if dx*dx + dy*dy <= r2 {
                    let x = center.0 + dx
                    let y = center.1 + dy
                    
                    if x >= 0 && x < width && y >= 0 && y < bitmap.count / width {
                        sum += Int(bitmap[y * width + x])
                    }
                }
            }
        }
        
        return sum
    }
    
    // MARK: - Kalman Filter
    private func updateKalmanFilter(with detection: BallDetection) {
        if var state = kalmanState {
            let dt = detection.timestamp - state.timestamp
            
            if dt > 0 && dt < 1.0 {
                let predictedX = state.x + state.vx * dt
                let predictedY = state.y + state.vy * dt
                
                let innovationX = Double(detection.position.x) - predictedX
                let innovationY = Double(detection.position.y) - predictedY
                
                let gain = measurementNoise / (measurementNoise + processNoise)
                
                state.x = predictedX + gain * innovationX
                state.y = predictedY + gain * innovationY
                state.vx = innovationX / dt
                state.vy = innovationY / dt
                state.timestamp = detection.timestamp
                
                kalmanState = state
            }
        } else {
            kalmanState = KalmanState(
                x: Double(detection.position.x),
                y: Double(detection.position.y),
                vx: 0.0,
                vy: 0.0,
                timestamp: detection.timestamp
            )
        }
    }
    
    private func predictBallPosition(timestamp: Double) -> BallDetection? {
        guard let state = kalmanState else { return nil }
        
        let dt = timestamp - state.timestamp
        guard dt > 0 && dt < 0.1 else { return nil }
        
        let predictedX = state.x + state.vx * dt
        let predictedY = state.y + state.vy * dt
        
        return BallDetection(
            position: CGPoint(x: predictedX, y: predictedY),
            radius: 20.0,
            confidence: 0.3,
            timestamp: timestamp
        )
    }
    
    // MARK: - History Management
    private func addToHistory(_ detection: BallDetection) {
        detectionHistory.append(detection)
        
        if detectionHistory.count > maxHistorySize {
            detectionHistory.removeFirst(detectionHistory.count - maxHistorySize)
        }
    }
    
    // MARK: - Apex Detection (IMPROVED - Research Design Compliant)
    /// Detects ball apex using velocity-based method
    /// According to research: y(t) velocity = 0, with negative acceleration
    func detectTossApex() -> BallApex? {
        guard detectionHistory.count >= 10 else { return nil }
        
        // Check cooldown
        guard let lastDetection = detectionHistory.last,
              lastDetection.timestamp - lastApexTime > apexCooldown else {
            return nil
        }
        
        // Calculate velocities for recent detections
        var velocities: [(index: Int, vy: Double, timestamp: Double)] = []
        
        for i in 1..<detectionHistory.count {
            let prev = detectionHistory[i - 1]
            let curr = detectionHistory[i]
            
            let dt = curr.timestamp - prev.timestamp
            guard dt > 0 else { continue }
            
            // Y-velocity (screen coordinates: positive = moving down)
            let vy = Double(curr.position.y - prev.position.y) / dt
            
            velocities.append((index: i, vy: vy, timestamp: curr.timestamp))
        }
        
        guard velocities.count >= 5 else { return nil }
        
        // Find where velocity crosses zero (going up → going down)
        for i in 2..<(velocities.count - 2) {
            let prev = velocities[i - 1]
            let curr = velocities[i]
            let next = velocities[i + 1]
            
            // Check for zero-crossing
            // Moving up: vy < 0 (negative)
            // Moving down: vy > 0 (positive)
            let isMovingUp = prev.vy < -20.0  // Moving up with sufficient speed
            let isCrossingZero = abs(curr.vy) < 30.0  // Near zero
            let isMovingDown = next.vy > 20.0  // Started moving down
            
            if isMovingUp && isCrossingZero && isMovingDown {
                // Calculate acceleration (should be positive/downward)
                let accel = (next.vy - prev.vy) / (next.timestamp - prev.timestamp)
                
                // Acceleration should be positive (downward) near apex
                guard accel > 50.0 else { continue }
                
                let apexDetection = detectionHistory[curr.index]
                
                // Validate height (should be in upper portion of frame)
                // Assuming typical frame size, apex should be in top 40%
                let imageHeight: CGFloat = 1920  // Typical height
                let heightRatio = apexDetection.position.y / imageHeight
                
                guard heightRatio < 0.4 else { continue }
                
                print("🎾 Ball apex detected (velocity-based)!")
                print("   - Time: \(String(format: "%.3f", apexDetection.timestamp))s")
                print("   - Position: (\(Int(apexDetection.position.x)), \(Int(apexDetection.position.y)))")
                print("   - Velocity: \(String(format: "%.1f", curr.vy)) px/s")
                print("   - Acceleration: \(String(format: "%.1f", accel)) px/s²")
                
                // Update cooldown
                lastApexTime = apexDetection.timestamp
                
                return BallApex(
                    timestamp: apexDetection.timestamp,
                    position: apexDetection.position,
                    height: apexDetection.position.y,
                    confidence: apexDetection.confidence
                )
            }
        }
        
        return nil
    }
    
    // MARK: - Legacy Method (kept for compatibility)
    @available(*, deprecated, message: "Use detectTossApex() instead")
    func detectTossApex(smoothingWindow: Int = 5) -> (time: Double, height: CGFloat)? {
        return detectTossApex().map { ($0.timestamp, $0.height) }
    }
    
    // MARK: - Reset
    func reset() {
        kalmanState = nil
        detectionHistory.removeAll()
        lastApexTime = 0.0
        print("🎾 BallTracker reset")
    }
    
    // MARK: - Utility
    func getDetectionHistory() -> [BallDetection] {
        return detectionHistory
    }
    
    func getRecentDetections(duration: TimeInterval) -> [BallDetection] {
        guard let lastDetection = detectionHistory.last else { return [] }
        
        let cutoffTime = lastDetection.timestamp - duration
        return detectionHistory.filter { $0.timestamp >= cutoffTime }
    }
}
