//
//  EventDetector.swift
//  TennisServeAnalyzer
//
//  Key event detection for tennis serve analysis
//  - Trophy pose detection (video-driven)
//  - Impact detection (IMU-driven)
//  - Self-adaptive thresholds
//

import Foundation
import CoreGraphics
import Accelerate

// MARK: - Detected Events
struct TrophyPoseEvent {
    let timestamp: Double
    let pose: PoseData
    let tossApex: (time: Double, height: CGFloat)?
    let tossApexX: CGFloat?
    let filteredBalls: [BallDetection]?
    let confidence: Float
    
    // Trophy pose criteria
    let elbowAngle: Double?
    let shoulderAbduction: Double?
    let isValid: Bool
    
    // 🔧 追加: 詳細な角度データ（ボール頂点時の実際の角度）
    let rightElbowAngle: Double?
    let rightArmpitAngle: Double?
    let leftShoulderAngle: Double?
    let leftElbowAngle: Double?
}

struct ImpactEvent {
    let timestamp: Double
    let monotonicMs: Int64
    let peakAngularVelocity: Double  // rad/s
    let peakJerk: Double  // m/s³
    let spectralPower: Double  // String vibration power (50-120Hz)
    let confidence: Float
}

// MARK: - Event Detector
class EventDetector {
    // MARK: Properties
    private var imuHistory: [ServeSample] = []
    private let maxIMUHistory: Int = 2000  // ~10s at 200Hz
    
    // Adaptive thresholds (initialized with defaults, updated after first 3 serves)
    private var angularVelocityThreshold: Double = 20.0  // rad/s
    private var jerkThreshold: Double = 500.0  // m/s³
    private var calibrationServes: [[ServeSample]] = []
    private var isCalibrated: Bool = false
    
    // Configuration
    private let trophyElbowAngleRange: ClosedRange<Double> = 140...180  // Extended elbow
    private let trophyShoulderAbductionMin: Double = 45.0  // Degrees
    
    // MARK: - Trophy Pose Detection (Video-Driven)
    func detectTrophyPose(
        pose: PoseData,
        ballApex: (time: Double, height: CGFloat)?
    ) -> TrophyPoseEvent? {
        // Step 1: Check elbow extension (right arm for right-handed player)
        guard let elbowAngle = PoseDetector.calculateElbowAngle(from: pose, isRight: true) else {
            return nil
        }
        
        // Step 2: Check shoulder abduction
        guard let rightShoulder = pose.joints[.rightShoulder],
              let neck = pose.joints[.neck],
              let rightWrist = pose.joints[.rightWrist] else {
            return nil
        }
        
        let shoulderAbduction = calculateShoulderAbduction(
            shoulder: rightShoulder,
            neck: neck,
            wrist: rightWrist
        )
        
        // Step 3: Validate trophy criteria
        let isElbowExtended = trophyElbowAngleRange.contains(elbowAngle)
        let isShoulderAbducted = shoulderAbduction > trophyShoulderAbductionMin
        
        let isValid = isElbowExtended && isShoulderAbducted
        
        // Step 4: Confidence based on joint confidences
        let confidence = pose.averageConfidence
        
        guard isValid && confidence > 0.5 else {
            return nil
        }
        
        // 🔧 修正: 引数順序を構造体定義と一致させる
        return TrophyPoseEvent(
            timestamp: pose.timestamp,
            pose: pose,
            tossApex: ballApex,
            tossApexX: nil,              // 🆕 追加（EventDetectorでは未使用）
            filteredBalls: nil,          // 🆕 追加（EventDetectorでは未使用）
            confidence: confidence,
            elbowAngle: elbowAngle,
            shoulderAbduction: shoulderAbduction,
            isValid: true,
            rightElbowAngle: nil,
            rightArmpitAngle: nil,
            leftShoulderAngle: nil,
            leftElbowAngle: nil
        )
    }
    
    private func calculateShoulderAbduction(
        shoulder: CGPoint,
        neck: CGPoint,
        wrist: CGPoint
    ) -> Double {
        // Vector from neck to shoulder (torso reference)
        let torsoVector = CGPoint(
            x: shoulder.x - neck.x,
            y: shoulder.y - neck.y
        )
        
        // Vector from shoulder to wrist (arm)
        let armVector = CGPoint(
            x: wrist.x - shoulder.x,
            y: wrist.y - shoulder.y
        )
        
        // Calculate angle between vectors
        return PoseDetector.calculateAngle(
            point1: neck,
            point2: shoulder,
            point3: wrist
        )
    }
    
    // MARK: - Impact Detection (IMU-Driven)
    func addIMUSample(_ sample: ServeSample) {
        imuHistory.append(sample)
        
        // Keep history bounded
        if imuHistory.count > maxIMUHistory {
            imuHistory.removeFirst(imuHistory.count - maxIMUHistory)
        }
    }
    
    func detectImpact(in window: [ServeSample]) -> ImpactEvent? {
        guard window.count >= 20 else { return nil }  // Need minimum samples
        
        // Step 1: Calculate angular velocity magnitude
        var angularVelocities: [Double] = []
        for sample in window {
            let magnitude = sqrt(
                sample.gx * sample.gx +
                sample.gy * sample.gy +
                sample.gz * sample.gz
            )
            angularVelocities.append(magnitude)
        }
        
        // Step 2: Find peak angular velocity
        guard let peakOmega = angularVelocities.max(),
              let peakIndex = angularVelocities.firstIndex(of: peakOmega) else {
            return nil
        }
        
        // Check threshold
        guard peakOmega > angularVelocityThreshold else {
            return nil
        }
        
        // Step 3: Calculate jerk (derivative of acceleration)
        var jerks: [Double] = []
        for i in 1..<window.count {
            let dt = Double(window[i].monotonic_ms - window[i-1].monotonic_ms) / 1000.0
            guard dt > 0 else { continue }
            
            let dax = (window[i].ax - window[i-1].ax) / dt
            let day = (window[i].ay - window[i-1].ay) / dt
            let daz = (window[i].az - window[i-1].az) / dt
            
            let jerkMag = sqrt(dax*dax + day*day + daz*daz)
            jerks.append(jerkMag)
        }
        
        let peakJerk = jerks.max() ?? 0.0
        
        // Step 4: STFT for string vibration (50-120Hz band)
        let spectralPower = calculateSpectralPower(
            in: window,
            frequencyBand: 50...120,
            windowAroundPeak: peakIndex
        )
        
        // Step 5: Confidence based on multiple factors
        let omegaScore = min(peakOmega / 30.0, 1.0)  // Normalize to [0,1]
        let jerkScore = min(peakJerk / 1000.0, 1.0)
        let spectralScore = min(spectralPower / 100.0, 1.0)
        
        let confidence = Float((omegaScore + jerkScore + spectralScore) / 3.0)
        
        guard confidence > 0.5 else {
            return nil
        }
        
        let impactSample = window[peakIndex]
        
        return ImpactEvent(
            timestamp: Double(impactSample.monotonic_ms) / 1000.0,
            monotonicMs: impactSample.monotonic_ms,
            peakAngularVelocity: peakOmega,
            peakJerk: peakJerk,
            spectralPower: spectralPower,
            confidence: confidence
        )
    }
    
    // MARK: - Spectral Analysis
    private func calculateSpectralPower(
        in window: [ServeSample],
        frequencyBand: ClosedRange<Double>,
        windowAroundPeak: Int
    ) -> Double {
        // Extract window around peak (±50ms = ±10 samples at 200Hz)
        let start = max(0, windowAroundPeak - 10)
        let end = min(window.count - 1, windowAroundPeak + 10)
        
        let segment = Array(window[start...end])
        
        guard segment.count >= 16 else { return 0.0 }  // Need power-of-2 samples
        
        // Extract acceleration magnitude
        var signal: [Float] = segment.map { sample in
            Float(sqrt(sample.ax*sample.ax + sample.ay*sample.ay + sample.az*sample.az))
        }
        
        // Pad to power of 2
        let fftSize = 32
        while signal.count < fftSize {
            signal.append(0.0)
        }
        signal = Array(signal.prefix(fftSize))
        
        // Perform FFT
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return 0.0
        }
        
        var realp = [Float](repeating: 0.0, count: fftSize / 2)
        var imagp = [Float](repeating: 0.0, count: fftSize / 2)
        
        return realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                
                signal.withUnsafeBytes { ptr in
                    ptr.bindMemory(to: DSPComplex.self).baseAddress.map {
                        vDSP_ctoz($0, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                }
                
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                
                // Calculate magnitude
                var magnitudes = [Float](repeating: 0.0, count: fftSize / 2)
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                
                // Sum power in frequency band
                let dt = 0.005  // 200Hz = 5ms interval
                let fs = 1.0 / dt  // Sampling frequency
                
                var bandPower: Double = 0.0
                for i in 0..<magnitudes.count {
                    let frequency = Double(i) * fs / Double(fftSize)
                    if frequencyBand.contains(frequency) {
                        bandPower += Double(magnitudes[i] * magnitudes[i])
                    }
                }
                
                vDSP_destroy_fftsetup(fftSetup)
                
                return bandPower
            }
        }
    }
    
    // MARK: - Adaptive Calibration
    func calibrateThresholds(fromServe samples: [ServeSample]) {
        calibrationServes.append(samples)
        
        // Calibrate after 3 serves
        if calibrationServes.count >= 3 && !isCalibrated {
            performCalibration()
            isCalibrated = true
        }
    }
    
    private func performCalibration() {
        var allPeaks: [Double] = []
        var allJerks: [Double] = []
        
        for serve in calibrationServes {
            // Find peaks in this serve
            for sample in serve {
                let omega = sqrt(sample.gx*sample.gx + sample.gy*sample.gy + sample.gz*sample.gz)
                allPeaks.append(omega)
            }
            
            // Calculate jerks
            for i in 1..<serve.count {
                let dt = Double(serve[i].monotonic_ms - serve[i-1].monotonic_ms) / 1000.0
                guard dt > 0 else { continue }
                
                let dax = (serve[i].ax - serve[i-1].ax) / dt
                let day = (serve[i].ay - serve[i-1].ay) / dt
                let daz = (serve[i].az - serve[i-1].az) / dt
                
                let jerk = sqrt(dax*dax + day*day + daz*daz)
                allJerks.append(jerk)
            }
        }
        
        // Set thresholds at 90th percentile
        if !allPeaks.isEmpty {
            allPeaks.sort()
            let index = Int(Double(allPeaks.count) * 0.9)
            angularVelocityThreshold = allPeaks[min(index, allPeaks.count - 1)] * 0.8
            print("📊 Calibrated angular velocity threshold: \(String(format: "%.2f", angularVelocityThreshold)) rad/s")
        }
        
        if !allJerks.isEmpty {
            allJerks.sort()
            let index = Int(Double(allJerks.count) * 0.9)
            jerkThreshold = allJerks[min(index, allJerks.count - 1)] * 0.8
            print("📊 Calibrated jerk threshold: \(String(format: "%.2f", jerkThreshold)) m/s³")
        }
    }
    
    // MARK: - Reset
    func reset() {
        imuHistory.removeAll()
        calibrationServes.removeAll()
        isCalibrated = false
    }
    
    // MARK: - Utility
    func getRecentIMU(duration: TimeInterval) -> [ServeSample] {
        guard let lastSample = imuHistory.last else { return [] }
        
        let cutoffMs = lastSample.monotonic_ms - Int64(duration * 1000)
        return imuHistory.filter { $0.monotonic_ms >= cutoffMs }
    }
}
