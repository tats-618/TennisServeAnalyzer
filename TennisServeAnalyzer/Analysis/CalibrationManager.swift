//
//  CalibrationResult.swift
//  TennisServeAnalyzer
//
//  Created by 島本健生 on 2025/10/28.
//


//
//  CalibrationManager.swift
//  TennisServeAnalyzer
//
//  IMU Calibration System (safe & robust)
//  - Static phase: Gravity → S→W transformation
//  - Swing phase: PCA → Swing plane/Shaft axis → R frame
//  - Quality metrics
//  - Main-thread safe @Published updates
//

import Foundation
import simd
import Accelerate
import Combine

// MARK: - Calibration Result
public struct CalibrationResult {
    // Rotation matrices
    public let sensorToWorld: simd_float3x3  // S → W (gravity aligned)
    public let sensorToRacket: simd_float3x3 // S → R (racket frame)

    // Calibration quality
    public let gravityAlignmentError: Double // degrees or %
    public let swingPlaneConsistency: Double // 0-1
    public let quality: Float                // Overall quality 0-1

    public var isValid: Bool {
        return quality > 0.7 && gravityAlignmentError < 5.0
    }
}

// MARK: - Calibration State
public enum CalibrationState: Equatable {
    case idle
    case collectingStatic
    case collectingSwings
    case completed(CalibrationResult)
    case failed(String)

    public static func == (lhs: CalibrationState, rhs: CalibrationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.collectingStatic, .collectingStatic),
             (.collectingSwings, .collectingSwings):
            return true
        case (.completed, .completed):
            return true // 値の中身までは比較しない
        case (.failed, .failed):
            return true // エラーメッセージは無視して「失敗」として同一扱い
        default:
            return false
        }
    }
}


// MARK: - Calibration Manager
final class CalibrationManager: ObservableObject {

    // MARK: Published UI State (must only be mutated on main thread)
    @Published private(set) var state: CalibrationState = .idle
    @Published private(set) var progress: Float = 0.0

    // MARK: Internal Buffers (guarded by queue)
    // Static calibration (2 seconds at 200Hz = 400 samples)
    private var staticSamples: [ServeSample] = []
    private let requiredStaticSamples: Int = 300  // ~1.5s minimum

    // Swing calibration (5 swings)
    private var swingSamples: [[ServeSample]] = []
    private let requiredSwings: Int = 5

    // Results (guarded by queue)
    private var calibrationResult: CalibrationResult?

    // MARK: Concurrency / Safety
    private let workQueue = DispatchQueue(label: "CalibrationManager.workQueue", qos: .userInitiated)
    private let dataQueue = DispatchQueue(label: "CalibrationManager.dataQueue", qos: .userInitiated)

    // MARK: Lifecycle
    init() {}

    // MARK: Public API

    /// Start the whole calibration flow.
    func startCalibration() {
        // Reset data on a protected queue
        dataQueue.async {
            self.staticSamples.removeAll(keepingCapacity: true)
            self.swingSamples.removeAll(keepingCapacity: true)
            self.calibrationResult = nil
        }
        // Update UI state on main
        setState(.collectingStatic)
        setProgress(0.0)
        debugLog("🎯 Starting calibration…")
    }

    /// Add one IMU sample during the static phase.
    func addStaticSample(_ sample: ServeSample) {
        guard currentStateIs(.collectingStatic) else { return }

        var countAfterAppend: Int = 0
        dataQueue.sync {
            self.staticSamples.append(sample)
            countAfterAppend = self.staticSamples.count
        }

        let prog = Float(min(countAfterAppend, requiredStaticSamples)) / Float(requiredStaticSamples)
        setProgress(prog)

        if countAfterAppend >= requiredStaticSamples {
            finishStaticPhase()
        }
    }

    /// Transition from static phase to swing phase after validation.
    private func finishStaticPhase() {
        // Validate on background queue to avoid blocking UI
        workQueue.async {
            let isStable = self.validateStaticStability()

            if isStable {
                self.setState(.collectingSwings)
                self.setProgress(0.0)
                self.debugLog("📊 Gravity calibration successful, ready for swings")
            } else {
                self.setState(.failed("Static phase unstable - please hold still"))
                self.debugLog("❌ Static calibration failed: device was moving")
            }
        }
    }

    /// Add one swing worth of samples during the swing phase.
    func addSwing(_ samples: [ServeSample]) {
        guard currentStateIs(.collectingSwings) else { return }

        // Validate movement quickly
        guard validateSwing(samples) else {
            debugLog("⚠️ Swing rejected: insufficient movement")
            return
        }

        var swingsCount = 0
        dataQueue.sync {
            self.swingSamples.append(samples)
            swingsCount = self.swingSamples.count
        }

        let prog = Float(min(swingsCount, requiredSwings)) / Float(requiredSwings)
        setProgress(prog)
        debugLog("✅ Swing \(swingsCount)/\(requiredSwings) recorded")

        if swingsCount >= requiredSwings {
            finishSwingPhase()
        }
    }

    /// Finalize swing phase and compute calibration.
    private func finishSwingPhase() {
        workQueue.async {
            self.debugLog("✅ Swing phase complete")
            guard let result = self.performCalibration() else {
                self.setState(.failed("Calibration computation failed"))
                self.debugLog("❌ Calibration failed")
                return
            }
            // Save and report
            self.dataQueue.async { self.calibrationResult = result }
            self.setState(.completed(result))
            self.debugLog("✅ Calibration complete - Quality: \(String(format: "%.2f", result.quality))")
        }
    }

    /// Access the most recent result (thread-safe).
    func getCurrentResult() -> CalibrationResult? {
        var result: CalibrationResult?
        dataQueue.sync { result = self.calibrationResult }
        return result
    }

    /// Reset to idle (clears buffers).
    func reset() {
        dataQueue.async {
            self.staticSamples.removeAll(keepingCapacity: false)
            self.swingSamples.removeAll(keepingCapacity: false)
            self.calibrationResult = nil
        }
        setProgress(0.0)
        setState(.idle)
    }

    // MARK: Validation / Computation

    /// Static stability: ensure acceleration variance is small.
    private func validateStaticStability() -> Bool {
        var samples: [ServeSample] = []
        dataQueue.sync { samples = self.staticSamples }

        guard samples.count >= 10 else { return false }

        // Variance per axis
        let ax = samples.map { $0.ax }
        let ay = samples.map { $0.ay }
        let az = samples.map { $0.az }

        func variance(_ xs: [Double]) -> Double {
            guard !xs.isEmpty else { return .infinity }
            let mean = xs.reduce(0, +) / Double(xs.count)
            let v = xs.reduce(0) { $0 + pow($1 - mean, 2) } / Double(xs.count)
            return v
        }

        let varX = variance(ax)
        let varY = variance(ay)
        let varZ = variance(az)
        let maxVar = max(varX, varY, varZ)

        // Should be < 0.01 (≈ 0.1 g^2 if ax/ay/az are in m/s^2 normalized-ish); tune as needed.
        let stable = maxVar < 0.01
        debugLog("🔎 Static variance: x=\(varX), y=\(varY), z=\(varZ), max=\(maxVar), stable=\(stable)")
        return stable
    }

    /// Swing validity: must have a clear angular velocity peak.
    private func validateSwing(_ samples: [ServeSample]) -> Bool {
        guard samples.count >= 20 else { return false }
        let maxOmega = samples.map { sqrt($0.gx*$0.gx + $0.gy*$0.gy + $0.gz*$0.gz) }.max() ?? 0.0
        return maxOmega > 10.0
    }

    /// Full calibration: S→W (gravity) and S→R (PCA on swings), plus quality metrics.
    private func performCalibration() -> CalibrationResult? {
        guard let sToW = computeSensorToWorld() else { return nil }
        guard let sToR = computeSensorToRacket() else { return nil }

        let gravityError = computeGravityAlignmentError()
        let swingConsistency = computeSwingConsistency()

        // Combine—as spec, keep simple and monotone
        let quality = Float(max(0.0, min(1.0, (1.0 - gravityError / 10.0) * swingConsistency)))

        return CalibrationResult(
            sensorToWorld: sToW,
            sensorToRacket: sToR,
            gravityAlignmentError: gravityError,
            swingPlaneConsistency: swingConsistency,
            quality: quality
        )
    }

    // Step 1: Gravity-based S→W
    private func computeSensorToWorld() -> simd_float3x3? {
        var samples: [ServeSample] = []
        dataQueue.sync { samples = self.staticSamples }
        guard !samples.isEmpty else { return nil }

        let avgAx = samples.map { $0.ax }.reduce(0, +) / Double(samples.count)
        let avgAy = samples.map { $0.ay }.reduce(0, +) / Double(samples.count)
        let avgAz = samples.map { $0.az }.reduce(0, +) / Double(samples.count)

        let gravityS = simd_float3(Float(avgAx), Float(avgAy), Float(avgAz))
        let mag = simd_length(gravityS)
        guard mag > 0.5 else { return nil } // sanity

        let gDir = gravityS / mag
        let worldZ = -gDir // world Z up (opposite gravity)

        // Choose an arbitrary X in the horizontal plane
        let worldX: simd_float3 = abs(worldZ.x) < 0.9
            ? simd_normalize(simd_cross(simd_float3(1, 0, 0), worldZ))
            : simd_normalize(simd_cross(simd_float3(0, 1, 0), worldZ))

        let worldY = simd_cross(worldZ, worldX)

        // Columns are world axes expressed in sensor frame
        return simd_float3x3(worldX, worldY, worldZ)
    }

    // Step 2: PCA-based S→R
    private func computeSensorToRacket() -> simd_float3x3? {
        var swings: [[ServeSample]] = []
        dataQueue.sync { swings = self.swingSamples }
        guard swings.count >= 3 else { return nil }

        // Collect high-velocity angular vectors near impact
        var omegas: [simd_float3] = []
        omegas.reserveCapacity(1024)

        for swing in swings {
            for s in swing {
                let ω = simd_float3(Float(s.gx), Float(s.gy), Float(s.gz))
                let mag = simd_length(ω)
                if mag > 15.0 { omegas.append(ω) }
            }
        }
        guard omegas.count >= 20 else { return nil }

        // First principal component
        let axis = computePCA(vectors: omegas)

        // Racket frame:
        // X: along shaft (principal swing axis)
        // Y: perpendicular (in swing plane)
        // Z: face normal (perpendicular to swing plane)
        let racketX = simd_normalize(axis)
        let racketY: simd_float3 = abs(racketX.z) < 0.9
            ? simd_normalize(simd_cross(simd_float3(0, 0, 1), racketX))
            : simd_normalize(simd_cross(simd_float3(1, 0, 0), racketX))
        let racketZ = simd_cross(racketX, racketY)

        return simd_float3x3(racketX, racketY, racketZ)
    }

    // Simple PCA (power iteration for largest eigenvector of covariance)
    private func computePCA(vectors: [simd_float3]) -> simd_float3 {
        guard !vectors.isEmpty else { return simd_float3(1, 0, 0) }

        let mean = vectors.reduce(simd_float3.zero, +) / Float(vectors.count)
        let centered = vectors.map { $0 - mean }

        // Covariance 3x3
        var cov = simd_float3x3()
        for v in centered {
            cov[0] += v * v.x
            cov[1] += v * v.y
            cov[2] += v * v.z
        }
        cov[0] /= Float(centered.count)
        cov[1] /= Float(centered.count)
        cov[2] /= Float(centered.count)

        // Power iteration
        var e = simd_float3(1, 0, 0)
        for _ in 0..<24 {
            e = cov * e
            let len = simd_length(e)
            if len > 0 { e /= len }
        }
        return e
    }

    // MARK: - Quality Metrics

    private func computeGravityAlignmentError() -> Double {
        var samples: [ServeSample] = []
        dataQueue.sync { samples = self.staticSamples }
        guard !samples.isEmpty else { return 999.0 }

        let avgAx = samples.map { $0.ax }.reduce(0, +) / Double(samples.count)
        let avgAy = samples.map { $0.ay }.reduce(0, +) / Double(samples.count)
        let avgAz = samples.map { $0.az }.reduce(0, +) / Double(samples.count)

        let measured = sqrt(avgAx*avgAx + avgAy*avgAy + avgAz*avgAz)
        let expected = 9.8 // m/s^2
        let errorPct = abs(measured - expected) / expected * 100.0
        return errorPct
    }

    private func computeSwingConsistency() -> Double {
        var swings: [[ServeSample]] = []
        dataQueue.sync { swings = self.swingSamples }
        guard swings.count >= 2 else { return 0.0 }

        var peaks: [Double] = []
        peaks.reserveCapacity(swings.count)

        for swing in swings {
            let maxΩ = swing.map { sqrt($0.gx*$0.gx + $0.gy*$0.gy + $0.gz*$0.gz) }.max() ?? 0.0
            peaks.append(maxΩ)
        }

        guard let mean = (peaks.isEmpty ? nil : peaks.reduce(0, +) / Double(peaks.count)), mean > 0 else {
            return 0.0
        }

        let variance = peaks.reduce(0) { $0 + pow($1 - mean, 2) } / Double(peaks.count)
        let std = sqrt(variance)
        let cv = std / mean // coefficient of variation (lower is better)

        // Map CV to [0,1] consistency score (tunable)
        // cv 0.0 → 1.0, 0.5 → 0.0
        let score = max(0.0, min(1.0, 1.0 - cv / 0.5))
        return score
    }

    // MARK: - Helpers (Main-thread setters & state checks)

    private func setState(_ newState: CalibrationState) {
        if Thread.isMainThread {
            self.state = newState
        } else {
            DispatchQueue.main.async { self.state = newState }
        }
    }

    private func setProgress(_ value: Float) {
        let clamped = max(0.0, min(1.0, value))
        if Thread.isMainThread {
            self.progress = clamped
        } else {
            DispatchQueue.main.async { self.progress = clamped }
        }
    }

    private func currentStateIs(_ s: CalibrationState) -> Bool {
        var current: CalibrationState = .idle
        if Thread.isMainThread {
            current = state
        } else {
            // Read safely on main to avoid UI race (state is @Published)
            DispatchQueue.main.sync { current = self.state }
        }
        return current == s
    }

    private func debugLog(_ msg: String) {
        #if DEBUG
        print("[CalibrationManager] \(msg) | main=\(Thread.isMainThread)")
        #endif
    }
}
