//
//  BallTracker.swift (100% COMPLETE VERSION)
//  TennisServeAnalyzer
//
//  🎯 APEX DETECTION WITH PARABOLIC FIT
//
//  CRITICAL IMPROVEMENTS:
//  1. ✅ Median smoothing for velocity (noise reduction)
//  2. ✅ Relaxed thresholds for slow toss (-20→-10, accel 50→20)
//  3. ✅ Parabolic fit for sub-frame apex precision
//  4. ✅ Enhanced Kalman with gravity
//  5. ✅ Longer prediction window (150ms)
//

import CoreImage
import CoreMedia
import UIKit
import Accelerate

// MARK: - Ball Detection Result (unchanged)
struct BallDetection {
    let position: CGPoint
    let radius: CGFloat
    let confidence: Float
    let timestamp: Double
    let imageSize: CGSize
    
    var isValid: Bool {
        return confidence > 0.15 && radius > 3.0 && radius < 200.0
    }
}

// MARK: - Enhanced Kalman Filter State
private struct KalmanState {
    var x: Double = 0.0
    var y: Double = 0.0
    var vx: Double = 0.0
    var vy: Double = 0.0
    var timestamp: Double = 0.0
    
    var px: Double = 100.0
    var py: Double = 100.0
    var pvx: Double = 50.0
    var pvy: Double = 50.0
}

// MARK: - Ball Tracker (100% COMPLETE)
class BallTracker {
    // MARK: Properties
    private let yoloDetector: YOLOBallDetector
    
    // Enhanced Kalman filter with gravity
    private var kalmanState: KalmanState?
    private let processNoise: Double = 15.0
    private let measurementNoise: Double = 8.0
    private let gravity: Double = 9.8 * 30.0  // px/s²
    
    // Detection history
    private var detectionHistory: [BallDetection] = []
    private let maxHistorySize: Int = 180
    
    // Apex detection state
    private var lastApexTime: Double = 0.0
    private let apexCooldown: Double = 1.2
    
    // Prediction configuration
    private let maxPredictionTime: Double = 0.15
    private let predictionConfidenceDecay: Float = 0.7
    
    // MARK: - Initialization
    init() {
        yoloDetector = YOLOBallDetector()
        print("🎾 BallTracker initialized (COMPLETE: median + parabolic fit)")
    }
    
    // MARK: - Utility: Median of 3 values
    private func median3(_ a: Double, _ b: Double, _ c: Double) -> Double {
        return [a, b, c].sorted()[1]
    }
    
    // MARK: - Main Tracking Method
    func trackBall(
        from sampleBuffer: CMSampleBuffer,
        timestamp: Double
    ) -> BallDetection? {
        if let detection = yoloDetector.detectBall(
            from: sampleBuffer,
            timestamp: timestamp
        ) {
            updateKalmanFilter(with: detection)
            addToHistory(detection)
            return detection
        }
        
        return predictBallPosition(timestamp: timestamp)
    }
    
    // MARK: - Enhanced Kalman Filter with Gravity
    private func updateKalmanFilter(with detection: BallDetection) {
        if var state = kalmanState {
            let dt = detection.timestamp - state.timestamp
            
            guard dt > 0 && dt < 1.0 else {
                kalmanState = initializeKalmanState(with: detection)
                return
            }
            
            // Predict with gravity
            let predictedX = state.x + state.vx * dt
            let predictedY = state.y + state.vy * dt + 0.5 * gravity * dt * dt
            let predictedVx = state.vx
            let predictedVy = state.vy + gravity * dt
            
            // Predict uncertainty
            state.px += state.pvx * dt + processNoise
            state.py += state.pvy * dt + processNoise
            state.pvx += processNoise
            state.pvy += processNoise
            
            // Innovation
            let innovationX = Double(detection.position.x) - predictedX
            let innovationY = Double(detection.position.y) - predictedY
            
            // Kalman gain
            let kx = state.px / (state.px + measurementNoise)
            let ky = state.py / (state.py + measurementNoise)
            let kvx = state.pvx / (state.pvx + measurementNoise * 2.0)
            let kvy = state.pvy / (state.pvy + measurementNoise * 2.0)
            
            // Update
            state.x = predictedX + kx * innovationX
            state.y = predictedY + ky * innovationY
            state.vx = predictedVx + kvx * (innovationX / dt)
            state.vy = predictedVy + kvy * (innovationY / dt)
            state.timestamp = detection.timestamp
            
            // Covariance update
            state.px *= (1.0 - kx)
            state.py *= (1.0 - ky)
            state.pvx *= (1.0 - kvx)
            state.pvy *= (1.0 - kvy)
            
            kalmanState = state
            
        } else {
            kalmanState = initializeKalmanState(with: detection)
        }
    }
    
    private func initializeKalmanState(with detection: BallDetection) -> KalmanState {
        return KalmanState(
            x: Double(detection.position.x),
            y: Double(detection.position.y),
            vx: 0.0,
            vy: 0.0,
            timestamp: detection.timestamp,
            px: 100.0,
            py: 100.0,
            pvx: 50.0,
            pvy: 50.0
        )
    }
    
    // MARK: - Prediction with Gravity
    private func predictBallPosition(timestamp: Double) -> BallDetection? {
        guard let state = kalmanState else { return nil }
        
        let dt = timestamp - state.timestamp
        guard dt > 0 && dt < maxPredictionTime else { return nil }
        
        let predictedX = state.x + state.vx * dt
        let predictedY = state.y + state.vy * dt + 0.5 * gravity * dt * dt
        
        let confidenceDecay = Float(exp(-dt / 0.05))
        let predictedConfidence = 0.3 * confidenceDecay * predictionConfidenceDecay
        
        let lastImageSize = detectionHistory.last?.imageSize ?? CGSize(width: 1280, height: 720)
        
        guard predictedX >= 0 && predictedX <= Double(lastImageSize.width) &&
              predictedY >= 0 && predictedY <= Double(lastImageSize.height) else {
            return nil
        }
        
        return BallDetection(
            position: CGPoint(x: predictedX, y: predictedY),
            radius: 15.0,
            confidence: predictedConfidence,
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
    
    // MARK: - 🎯 APEX DETECTION (100% COMPLETE with Parabolic Fit)
    func detectTossApex() -> BallApex? {
        guard detectionHistory.count >= 10 else { return nil }
        
        guard let last = detectionHistory.last,
              last.timestamp - lastApexTime > apexCooldown else {
            return nil
        }
        
        // Use recent ~0.3s (24 frames at 120fps)
        let recent = Array(detectionHistory.suffix(24))
        guard recent.count >= 10 else { return nil }
        
        // Calculate velocity with median smoothing
        var vels: [(i: Int, vy: Double, t: Double)] = []
        
        for i in 2..<recent.count {
            let p0 = recent[i-2]
            let p1 = recent[i-1]
            let p2 = recent[i]
            
            let dt01 = max(p1.timestamp - p0.timestamp, 1e-3)
            let dt12 = max(p2.timestamp - p1.timestamp, 1e-3)
            
            let vy01 = Double(p1.position.y - p0.position.y) / dt01
            let vy12 = Double(p2.position.y - p1.position.y) / dt12
            
            // Median of 3 values for noise reduction
            let vyMed = median3(vy01, vy12, (vy01 + vy12) / 2.0)
            
            vels.append((i, vyMed, p2.timestamp))
        }
        
        guard vels.count >= 5 else { return nil }
        
        // 🎯 RELAXED thresholds for slow toss
        for i in 2..<(vels.count - 2) {
            let prev = vels[i-1]
            let curr = vels[i]
            let next = vels[i+1]
            
            // RELAXED: -20→-10, ±30→±20, 20→10
            let isUp = prev.vy < -10.0      // Was -20
            let near0 = abs(curr.vy) < 20.0  // Was 30
            let isDown = next.vy > 10.0      // Was 20
            
            if isUp && near0 && isDown {
                let accel = (next.vy - prev.vy) / max(next.t - prev.t, 1e-3)
                
                guard accel > 20.0 else { continue }  // Was 50
                
                // 🎯 Try parabolic fit for sub-frame precision
                if let refined = refineApexByParabola(history: recent) {
                    lastApexTime = refined.timestamp
                    print("🎾 Apex detected (PARABOLIC FIT)!")
                    print("   - Time: \(String(format: "%.3f", refined.timestamp))s")
                    print("   - Position: (\(Int(refined.position.x)), \(Int(refined.position.y)))")
                    print("   - Velocity: \(String(format: "%.1f", curr.vy)) px/s")
                    print("   - Accel: \(String(format: "%.1f", accel)) px/s²")
                    return refined
                }
                
                // Fallback: discrete point
                let apex = recent[curr.i]
                lastApexTime = apex.timestamp
                
                print("🎾 Apex detected (DISCRETE)!")
                print("   - Time: \(String(format: "%.3f", apex.timestamp))s")
                print("   - Position: (\(Int(apex.position.x)), \(Int(apex.position.y)))")
                
                return BallApex(
                    timestamp: apex.timestamp,
                    position: apex.position,
                    height: apex.position.y,
                    confidence: apex.confidence
                )
            }
        }
        
        return nil
    }
    
    // MARK: - 🎯 Parabolic Fit (Sub-frame Apex Estimation)
    private func refineApexByParabola(history: [BallDetection]) -> BallApex? {
        guard history.count >= 8 else { return nil }
        
        // Time origin
        let t0 = history.first!.timestamp
        
        // Build normal equations for y = a*t^2 + b*t + c
        var S0 = 0.0, S1 = 0.0, S2 = 0.0, S3 = 0.0, S4 = 0.0
        var Ty0 = 0.0, Ty1 = 0.0, Ty2 = 0.0
        var last = history.last!
        
        for d in history {
            let t = d.timestamp - t0
            let y = Double(d.position.y)
            let t2 = t * t
            let t3 = t2 * t
            let t4 = t2 * t2
            
            S0 += 1.0
            S1 += t
            S2 += t2
            S3 += t3
            S4 += t4
            Ty0 += y
            Ty1 += t * y
            Ty2 += t2 * y
            
            last = d
        }
        
        // Solve normal equations using Cramer's rule
        func det3(_ a: Double, _ b: Double, _ c: Double,
                  _ d: Double, _ e: Double, _ f: Double,
                  _ g: Double, _ h: Double, _ i: Double) -> Double {
            return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        }
        
        let D = det3(S4, S3, S2,  S3, S2, S1,  S2, S1, S0)
        guard abs(D) > 1e-9 else { return nil }
        
        let Dx = det3(Ty2, S3, S2,  Ty1, S2, S1,  Ty0, S1, S0)
        let Dy = det3(S4, Ty2, S2,  S3, Ty1, S1,  S2, Ty0, S0)
        let Dz = det3(S4, S3, Ty2,  S3, S2, Ty1,  S2, S1, Ty0)
        
        let a = Dx / D
        let b = Dy / D
        let c = Dz / D
        
        // Check if parabola is valid (not horizontal line)
        guard abs(a) > 1e-6 else { return nil }
        
        // Find apex (vertex of parabola)
        let tApex = -b / (2.0 * a)
        
        // Validate apex is within reasonable range
        guard tApex.isFinite,
              tApex >= 0,
              tApex <= (last.timestamp - t0) + 0.1 else {
            return nil
        }
        
        let yApex = a * tApex * tApex + b * tApex + c
        
        // Interpolate x position linearly between nearest points
        var tNear0 = 0.0, xNear0 = 0.0, tNear1 = 0.0, xNear1 = 0.0
        var found = false
        
        for i in 1..<history.count {
            let tPrev = history[i-1].timestamp - t0
            let tCurr = history[i].timestamp - t0
            
            if tPrev <= tApex && tApex <= tCurr {
                tNear0 = tPrev
                xNear0 = Double(history[i-1].position.x)
                tNear1 = tCurr
                xNear1 = Double(history[i].position.x)
                found = true
                break
            }
        }
        
        let xApex: Double
        if found && tNear1 > tNear0 {
            let r = (tApex - tNear0) / (tNear1 - tNear0)
            xApex = xNear0 * (1.0 - r) + xNear1 * r
        } else {
            xApex = Double(history.last!.position.x)
        }
        
        return BallApex(
            timestamp: t0 + tApex,
            position: CGPoint(x: xApex, y: yApex),
            height: yApex,
            confidence: history.last!.confidence
        )
    }
    
    // MARK: - Reset
    func reset() {
        kalmanState = nil
        detectionHistory.removeAll()
        lastApexTime = 0.0
        yoloDetector.reset()
        print("🎾 BallTracker (COMPLETE) reset")
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
    
    func getKalmanDebugInfo() -> String? {
        guard let state = kalmanState else { return nil }
        
        return """
        Kalman State:
          Position: (\(String(format: "%.1f", state.x)), \(String(format: "%.1f", state.y)))
          Velocity: (\(String(format: "%.1f", state.vx)), \(String(format: "%.1f", state.vy))) px/s
          Uncertainty: px=\(String(format: "%.1f", state.px)), py=\(String(format: "%.1f", state.py))
        """
    }
}
