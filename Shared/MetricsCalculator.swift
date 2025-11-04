//
//  MetricsCalculator.swift
//  TennisServeAnalyzer
//
//  Created by 島本健生 on 2025/10/28.
//

//
//  MetricsCalculator.swift
//  TennisServeAnalyzer
//
//  7-Metric Calculation and Scoring System
//  All metrics normalized to 0-100 using piecewise linear functions
//

import Foundation
import CoreGraphics

// MARK: - Serve Metrics
struct ServeMetrics: Codable {
    // Raw values
    let tossStabilityCV: Double
    let shoulderPelvisTiltDeg: Double
    let kneeFlexionDeg: Double
    let elbowAngleDeg: Double
    let racketDropDeg: Double
    let trunkTimingCorrelation: Double
    let tossToImpactMs: Double
    
    // Normalized scores (0-100)
    let score1_tossStability: Int
    let score2_shoulderPelvisTilt: Int
    let score3_kneeFlexion: Int
    let score4_elbowAngle: Int
    let score5_racketDrop: Int
    let score6_trunkTiming: Int
    let score7_tossToImpactTiming: Int
    
    // Total score (weighted average)
    let totalScore: Int
    
    // Metadata
    let timestamp: Date
    let flags: [String]
}

// MARK: - Metrics Calculator
class MetricsCalculator {
    
    // MARK: - Weights (sum = 100)
    private static let weights: [Double] = [15, 15, 15, 10, 15, 15, 15]
    
    // MARK: - Main Calculation
    static func calculateMetrics(
        trophyPose: TrophyPoseEvent,
        impactEvent: ImpactEvent,
        tossHistory: [BallDetection],
        imuHistory: [ServeSample],
        calibration: CalibrationResult? // 仮の型
    ) -> ServeMetrics {
        
        var flags: [String] = []
        
        // 1. Toss Stability
        let tossCV = calculateTossStability(tossHistory: tossHistory)
        let score1 = normalizeTossStability(cv: tossCV)
        
        // 2. Shoulder-Pelvis Tilt
        let shoulderTilt = calculateShoulderPelvisTilt(pose: trophyPose.pose)
        let score2 = normalizeShoulderPelvisTilt(tilt: shoulderTilt)
        
        // 3. Knee Flexion
        let kneeFlexion = calculateKneeFlexion(pose: trophyPose.pose)
        let score3 = normalizeKneeFlexion(angle: kneeFlexion)
        
        // 4. Elbow Angle
        let elbowAngle = trophyPose.elbowAngle ?? 0.0
        let score4 = normalizeElbowAngle(angle: elbowAngle)
        
        // 5. Racket Drop
        let racketDrop = calculateRacketDrop(
            imuHistory: imuHistory,
            impactTime: impactEvent.monotonicMs,
            calibration: calibration // 仮の引数
        )
        let score5 = normalizeRacketDrop(drop: racketDrop)
        
        if calibration == nil {
            flags.append("no_calibration")
        }
        
        // 6. Trunk Rotation Timing
        let trunkTiming = calculateTrunkRotationTiming(
            imuHistory: imuHistory,
            impactTime: impactEvent.monotonicMs
        )
        let score6 = normalizeTrunkTiming(correlation: trunkTiming)
        
        // 7. Toss to Impact Timing
        let tossToImpact = calculateTossToImpactDelay(
            tossTime: trophyPose.timestamp,
            impactTime: Double(impactEvent.monotonicMs) / 1000.0
        )
        let score7 = normalizeTossToImpactTiming(delay: tossToImpact)
        
        // Calculate total score
        let scores = [score1, score2, score3, score4, score5, score6, score7]
        let totalScore = calculateTotalScore(scores: scores.map { Double($0) })
        
        return ServeMetrics(
            tossStabilityCV: tossCV,
            shoulderPelvisTiltDeg: shoulderTilt,
            kneeFlexionDeg: kneeFlexion,
            elbowAngleDeg: elbowAngle,
            racketDropDeg: racketDrop,
            trunkTimingCorrelation: trunkTiming,
            tossToImpactMs: tossToImpact * 1000,
            score1_tossStability: score1,
            score2_shoulderPelvisTilt: score2,
            score3_kneeFlexion: score3,
            score4_elbowAngle: score4,
            score5_racketDrop: score5,
            score6_trunkTiming: score6,
            score7_tossToImpactTiming: score7,
            totalScore: totalScore,
            timestamp: Date(),
            flags: flags
        )
    }
    
    // MARK: - Individual Metrics
    
    // 1. Toss Stability (Coefficient of Variation)
    static func calculateTossStability(tossHistory: [BallDetection]) -> Double {
        let heights = tossHistory.map { $0.position.y }
        guard heights.count >= 2 else { return 999.0 }
        
        let mean = heights.reduce(0, +) / CGFloat(heights.count)
        let variance = heights.map { pow($0 - mean, 2) }.reduce(0, +) / CGFloat(heights.count)
        let stdDev = sqrt(variance)
        
        let cv = Double(stdDev / mean)
        return cv
    }
    
    static func normalizeTossStability(cv: Double) -> Int {
        // CV < 5%: 100 points
        // CV 5-10%: 80-100 points (linear)
        // CV 10-20%: 50-80 points (linear)
        // CV > 20%: 0-50 points (linear)
        
        if cv < 0.05 {
            return 100
        } else if cv < 0.10 {
            return Int(100 - (cv - 0.05) / 0.05 * 20)
        } else if cv < 0.20 {
            return Int(80 - (cv - 0.10) / 0.10 * 30)
        } else {
            return max(0, Int(50 - (cv - 0.20) / 0.20 * 50))
        }
    }
    
    // 2. Shoulder-Pelvis Tilt
    // ⬇️ 修正箇所: PoseDetector.swift に実装されたメソッドを呼び出すように変更
    static func calculateShoulderPelvisTilt(pose: PoseData) -> Double {
        // PoseDetector.swift に実装されたメソッドを呼び出す
        return PoseDetector.calculateShoulderPelvisTilt(from: pose) ?? 0.0
    }
    
    static func normalizeShoulderPelvisTilt(tilt: Double) -> Int {
        // Optimal: 10-20 degrees (100 points)
        // 5-10 or 20-30: 70-100 points
        // 0-5 or 30-45: 40-70 points
        // > 45: 0-40 points
        
        let absTilt = abs(tilt)
        
        if absTilt >= 10 && absTilt <= 20 {
            return 100
        } else if absTilt >= 5 && absTilt < 10 {
            return Int(70 + (absTilt - 5) / 5 * 30)
        } else if absTilt >= 20 && absTilt < 30 {
            return Int(100 - (absTilt - 20) / 10 * 30)
        } else if absTilt >= 0 && absTilt < 5 {
            return Int(40 + absTilt / 5 * 30)
        } else if absTilt >= 30 && absTilt < 45 {
            return Int(70 - (absTilt - 30) / 15 * 30)
        } else {
            return max(0, Int(40 - (absTilt - 45) / 15 * 40))
        }
    }
    
    // 3. Knee Flexion
    static func calculateKneeFlexion(pose: PoseData) -> Double {
        // Average of both knees
        let rightKnee = PoseDetector.calculateKneeAngle(from: pose, isRight: true) ?? 180.0
        let leftKnee = PoseDetector.calculateKneeAngle(from: pose, isRight: false) ?? 180.0
        
        return (rightKnee + leftKnee) / 2.0
    }
    
    static func normalizeKneeFlexion(angle: Double) -> Int {
        // Optimal: 130-150 degrees (100 points)
        // 120-130 or 150-160: 70-100 points
        // 100-120 or 160-180: 40-70 points
        // < 100: 0-40 points
        
        if angle >= 130 && angle <= 150 {
            return 100
        } else if angle >= 120 && angle < 130 {
            return Int(70 + (angle - 120) / 10 * 30)
        } else if angle >= 150 && angle < 160 {
            return Int(100 - (angle - 150) / 10 * 30)
        } else if angle >= 100 && angle < 120 {
            return Int(40 + (angle - 100) / 20 * 30)
        } else if angle >= 160 && angle <= 180 {
            return Int(70 - (angle - 160) / 20 * 30)
        } else {
            return max(0, Int(40 - (100 - angle) / 20 * 40))
        }
    }
    
    // 4. Elbow Angle (already calculated in TrophyPoseEvent)
    static func normalizeElbowAngle(angle: Double) -> Int {
        // Optimal: 160-180 degrees (extended) (100 points)
        // 140-160: 70-100 points
        // 120-140: 40-70 points
        // < 120: 0-40 points
        
        if angle >= 160 && angle <= 180 {
            return 100
        } else if angle >= 140 && angle < 160 {
            return Int(70 + (angle - 140) / 20 * 30)
        } else if angle >= 120 && angle < 140 {
            return Int(40 + (angle - 120) / 20 * 30)
        } else {
            return max(0, Int(40 * angle / 120))
        }
    }
    
    // 5. Racket Drop (requires IMU in racket frame)
    static func calculateRacketDrop(
        imuHistory: [ServeSample],
        impactTime: Int64,
        calibration: CalibrationResult? // 仮の型
    ) -> Double {
        // Find samples 200ms before impact
        let windowStart = impactTime - 200
        let windowEnd = impactTime
        
        let window = imuHistory.filter {
            $0.monotonic_ms >= windowStart && $0.monotonic_ms < windowEnd
        }
        
        guard !window.isEmpty else { return 0.0 }
        
        // Find minimum Z-axis acceleration (deepest drop)
        // In racket frame, negative Z means drop
        var minDrop = 0.0
        
        for sample in window {
            let az = sample.az  // In sensor frame for now
            minDrop = min(minDrop, az)
        }
        
        // Convert to degrees (approximate)
        // Assuming 1g drop ≈ 45 degrees
        let dropDegrees = abs(minDrop) * 45.0
        
        return dropDegrees
    }
    
    static func normalizeRacketDrop(drop: Double) -> Int {
        // Optimal: 40-60 degrees (100 points)
        // 30-40 or 60-80: 70-100 points
        // 20-30 or 80-100: 40-70 points
        // < 20 or > 100: 0-40 points
        
        if drop >= 40 && drop <= 60 {
            return 100
        } else if drop >= 30 && drop < 40 {
            return Int(70 + (drop - 30) / 10 * 30)
        } else if drop >= 60 && drop < 80 {
            return Int(100 - (drop - 60) / 20 * 30)
        } else if drop >= 20 && drop < 30 {
            return Int(40 + (drop - 20) / 10 * 30)
        } else if drop >= 80 && drop < 100 {
            return Int(70 - (drop - 80) / 20 * 30)
        } else if drop < 20 {
            return max(0, Int(40 * drop / 20))
        } else {
            return max(0, Int(40 - (drop - 100) / 50 * 40))
        }
    }
    
    // 6. Trunk Rotation Timing (correlation between racket drop and trunk rotation)
    static func calculateTrunkRotationTiming(
        imuHistory: [ServeSample],
        impactTime: Int64
    ) -> Double {
        // Window: 500ms before impact
        let windowStart = impactTime - 500
        let windowEnd = impactTime
        
        let window = imuHistory.filter {
            $0.monotonic_ms >= windowStart && $0.monotonic_ms < windowEnd
        }
        
        guard window.count >= 20 else { return 0.0 }
        
        // Extract two signals:
        // 1. Racket drop (Z-axis acceleration)
        // 2. Trunk rotation (Y-axis angular velocity)
        
        var dropSignal = window.map { $0.az }
        var rotationSignal = window.map { $0.gy }
        
        // Normalize
        dropSignal = normalize(signal: dropSignal)
        rotationSignal = normalize(signal: rotationSignal)
        
        // Cross-correlation to find phase lag
        let correlation = calculateCrossCorrelation(signal1: dropSignal, signal2: rotationSignal)
        
        return correlation
    }
    
    private static func normalize(signal: [Double]) -> [Double] {
        let mean = signal.reduce(0, +) / Double(signal.count)
        let stdDev = sqrt(signal.map { pow($0 - mean, 2) }.reduce(0, +) / Double(signal.count))
        
        guard stdDev > 0 else { return signal }
        
        return signal.map { ($0 - mean) / stdDev }
    }
    
    private static func calculateCrossCorrelation(signal1: [Double], signal2: [Double]) -> Double {
        let n = min(signal1.count, signal2.count)
        guard n > 0 else { return 0.0 }
        
        var sum = 0.0
        for i in 0..<n {
            sum += signal1[i] * signal2[i]
        }
        
        return sum / Double(n)
    }
    
    static func normalizeTrunkTiming(correlation: Double) -> Int {
        // Higher correlation = better timing
        // 0.7-1.0: 100 points
        // 0.5-0.7: 70-100 points
        // 0.3-0.5: 40-70 points
        // < 0.3: 0-40 points
        
        let absCorr = abs(correlation)
        
        if absCorr >= 0.7 {
            return 100
        } else if absCorr >= 0.5 {
            return Int(70 + (absCorr - 0.5) / 0.2 * 30)
        } else if absCorr >= 0.3 {
            return Int(40 + (absCorr - 0.3) / 0.2 * 30)
        } else {
            return max(0, Int(40 * absCorr / 0.3))
        }
    }
    
    // 7. Toss to Impact Timing
    static func calculateTossToImpactDelay(tossTime: Double, impactTime: Double) -> Double {
        return impactTime - tossTime
    }
    
    static func normalizeTossToImpactTiming(delay: Double) -> Int {
        // Optimal: 0.8-1.2 seconds (100 points)
        // 0.6-0.8 or 1.2-1.5: 70-100 points
        // 0.4-0.6 or 1.5-2.0: 40-70 points
        // < 0.4 or > 2.0: 0-40 points
        
        if delay >= 0.8 && delay <= 1.2 {
            return 100
        } else if delay >= 0.6 && delay < 0.8 {
            return Int(70 + (delay - 0.6) / 0.2 * 30)
        } else if delay >= 1.2 && delay < 1.5 {
            return Int(100 - (delay - 1.2) / 0.3 * 30)
        } else if delay >= 0.4 && delay < 0.6 {
            return Int(40 + (delay - 0.4) / 0.2 * 30)
        } else if delay >= 1.5 && delay < 2.0 {
            return Int(70 - (delay - 1.5) / 0.5 * 30)
        } else if delay < 0.4 {
            return max(0, Int(40 * delay / 0.4))
        } else {
            return max(0, Int(40 - (delay - 2.0) / 1.0 * 40))
        }
    }
    
    // MARK: - Total Score
    static func calculateTotalScore(scores: [Double]) -> Int {
        guard scores.count == weights.count else { return 0 }
        
        var total = 0.0
        for i in 0..<scores.count {
            total += scores[i] * weights[i] / 100.0
        }
        
        return Int(total)
    }
    
    // MARK: - Feedback Generation
    static func generateFeedback(metrics: ServeMetrics) -> String {
        // Find lowest score
        let scores = [
            (1, "トスの安定性", metrics.score1_tossStability),
            (2, "肩-骨盤の傾き", metrics.score2_shoulderPelvisTilt),
            (3, "膝の屈曲", metrics.score3_kneeFlexion),
            (4, "肘の角度", metrics.score4_elbowAngle),
            (5, "ラケットドロップ", metrics.score5_racketDrop),
            (6, "体幹回旋のタイミング", metrics.score6_trunkTiming),
            (7, "トス→インパクトのタイミング", metrics.score7_tossToImpactTiming)
        ]
        
        let sorted = scores.sorted { $0.2 < $1.2 }
        let weakest = sorted.first!
        
        // Generate advice based on weakest metric
        let advice: String
        
        switch weakest.0 {
        case 1:
            advice = "トスの高さを一定に保ちましょう。同じ位置に繰り返しトスできるよう練習しましょう。"
        case 2:
            advice = "トロフィーポーズで上体をもっと傾けましょう。肩のラインが骨盤より傾くイメージです。"
        case 3:
            advice = "膝をもっと曲げましょう。下半身のパワーを活用できます。"
        case 4:
            advice = "トロフィーポーズで肘をもっと伸ばしましょう。腕を高く上げる意識を持ちましょう。"
        case 5:
            advice = "ラケットをもっと深く落としましょう。背中側により大きく引くイメージです。"
        case 6:
            advice = "体幹回旋のタイミングを調整しましょう。ラケットが落ちきってから回旋を開始します。"
        case 7:
            advice = "トスとインパクトのタイミングを調整しましょう。トスの高さを少し変えてみましょう。"
        default:
            advice = "良いサーブです！この調子で練習を続けましょう。"
        }
        
        return advice
    }
}
