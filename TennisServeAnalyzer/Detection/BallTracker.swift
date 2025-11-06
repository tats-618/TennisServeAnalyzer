//
//  BallTracker.swift
//  TennisServeAnalyzer
//
//  IMPROVED: YOLO-based ball detection with IMAGE SIZE tracking
//

import CoreImage
import CoreMedia
import UIKit
import Accelerate

// MARK: - Ball Detection Result
struct BallDetection {
    let position: CGPoint  // Coordinates in SOURCE image space
    let radius: CGFloat
    let confidence: Float  // 0.0 - 1.0
    let timestamp: Double
    let imageSize: CGSize  // 🔧 NEW: Actual image size for correct scaling
    
    var isValid: Bool {
        return confidence > 0.4 && radius > 5.0 && radius < 100.0
    }
}

// MARK: - Kalman Filter State
private struct KalmanState {
    var x: Double = 0.0
    var y: Double = 0.0
    var vx: Double = 0.0
    var vy: Double = 0.0
    var timestamp: Double = 0.0
}

// MARK: - Ball Tracker (YOLO-based)
class BallTracker {
    // MARK: Properties
    private let yoloDetector: YOLOBallDetector
    
    // Kalman filter
    private var kalmanState: KalmanState?
    private let processNoise: Double = 10.0
    private let measurementNoise: Double = 5.0
    
    // Detection history
    private var detectionHistory: [BallDetection] = []
    private let maxHistorySize: Int = 120  // ~1s at 120fps
    
    // Apex detection state
    private var lastApexTime: Double = 0.0
    private let apexCooldown: Double = 1.5  // Minimum 1.5s between apex detections
    
    // MARK: - Initialization
    init() {
        yoloDetector = YOLOBallDetector()
        print("🎾 BallTracker initialized (YOLO-based + velocity apex detection)")
    }
    
    // MARK: - Main Tracking Method
    func trackBall(
        from sampleBuffer: CMSampleBuffer,
        timestamp: Double
    ) -> BallDetection? {
        // Use YOLO detection
        guard let detection = yoloDetector.detectBall(
            from: sampleBuffer,
            timestamp: timestamp
        ) else {
            return predictBallPosition(timestamp: timestamp)
        }
        
        // Update Kalman filter
        updateKalmanFilter(with: detection)
        
        // Add to history
        addToHistory(detection)
        
        return detection
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
        
        // 🔧 Use last known image size
        let lastImageSize = detectionHistory.last?.imageSize ?? CGSize(width: 1280, height: 720)
        
        return BallDetection(
            position: CGPoint(x: predictedX, y: predictedY),
            radius: 20.0,
            confidence: 0.3,
            timestamp: timestamp,
            imageSize: lastImageSize
        )
    }
    
    // MARK: - History Management
    private func addToHistory(_ detection: BallDetection) {
        detectionHistory.append(detection)
        
        if detectionHistory.count > maxHistorySize {
            detectionHistory.removeFirst(detectionHistory.count - maxHistorySize)
        }
    }
    
    // MARK: - Apex Detection (Velocity-based)
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
            let isMovingUp = prev.vy < -20.0
            let isCrossingZero = abs(curr.vy) < 30.0
            let isMovingDown = next.vy > 20.0
            
            if isMovingUp && isCrossingZero && isMovingDown {
                // Calculate acceleration
                let accel = (next.vy - prev.vy) / (next.timestamp - prev.timestamp)
                
                guard accel > 50.0 else { continue }
                
                let apexDetection = detectionHistory[curr.index]
                
                // Validate height
                let imageHeight = apexDetection.imageSize.height
                let heightRatio = apexDetection.position.y / imageHeight
                
                guard heightRatio < 0.4 else { continue }
                
                print("🎾 Ball apex detected (YOLO + velocity-based)!")
                print("   - Time: \(String(format: "%.3f", apexDetection.timestamp))s")
                print("   - Position: (\(Int(apexDetection.position.x)), \(Int(apexDetection.position.y)))")
                print("   - Velocity: \(String(format: "%.1f", curr.vy)) px/s")
                
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
    
    // MARK: - Reset
    func reset() {
        kalmanState = nil
        detectionHistory.removeAll()
        lastApexTime = 0.0
        yoloDetector.reset()
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
    
    func getPerformanceInfo() -> (fps: Double, avgMs: Double) {
        return yoloDetector.getPerformanceInfo()
    }
}
