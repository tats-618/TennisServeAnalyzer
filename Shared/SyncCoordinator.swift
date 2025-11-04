//
//  SyncCoordinator.swift
//  TennisServeAnalyzer
//
//  Created by 島本健生 on 2025/10/22.
//

//
//  SyncCoordinator.swift
//  TennisServeAnalyzer
//
//  P1: 時刻同期マネージャー
//

import Foundation
#if os(iOS)
import QuartzCore
#endif

/// 時刻同期情報
struct TimeSyncInfo: Codable {
    let t0_phone: Double
    let wallclock_iso: String
    let sync_version: String
    
    init(t0: Double) {
        self.t0_phone = t0
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.wallclock_iso = formatter.string(from: Date())
        
        self.sync_version = "1.0"
    }
    
    init(t0_phone: Double, wallclock_iso: String, sync_version: String) {
        self.t0_phone = t0_phone
        self.wallclock_iso = wallclock_iso
        self.sync_version = sync_version
    }
}

/// 軽打同期イベント
struct TapSyncEvent: Codable {
    let device: String
    let peak_ms: Int64
    let confidence: Double
    let event_type: String
}

/// 同期補正結果
struct SyncCorrection: Codable {
    let delta_ms: Double
    let method: String
    let confidence: Double
    let applied_at: String
}

/// P1: 時刻同期コーディネーター
class SyncCoordinator {
    
    // MARK: - Singleton
    static let shared = SyncCoordinator()
    
    // MARK: - Properties
    
    /// iPhone側の原点時刻（CACurrentMediaTime）
    private(set) var t0_phone: Double?
    
    /// Watch側の原点時刻（motion.timestamp の最初の値）
    private(set) var t0_watch: Double?
    
    /// 壁時計時刻（原点時刻のISO8601）
    private(set) var wallclock_t0: String?
    
    /// 軽打同期イベント履歴
    private var tapEvents: [TapSyncEvent] = []
    
    /// 補正履歴
    private var corrections: [SyncCorrection] = []
    
    /// 現在の補正値（ms）
    private(set) var currentDelta: Double = 0.0
    
    /// Watch側で最初のモーションタイムスタンプを受信したか
    private var hasSetInitialMotionTimestamp = false
    
    private init() {}
    
    // MARK: - iPhone側メソッド
    
    func generateT0Phone() -> TimeSyncInfo {
        #if os(iOS)
        let t0 = CACurrentMediaTime()
        self.t0_phone = t0
        
        let syncInfo = TimeSyncInfo(t0: t0)
        self.wallclock_t0 = syncInfo.wallclock_iso
        
        print("📍 iPhone: t0 generated = \(t0)")
        return syncInfo
        #else
        fatalError("generateT0Phone() should only be called on iOS")
        #endif
    }
    
    func detectAudioPeak(audioLevel: Float, timestamp: Double) -> TapSyncEvent? {
        guard let t0 = t0_phone else { return nil }
        
        if audioLevel > 0.7 {
            let peakMs = Int64((timestamp - t0) * 1000)
            let event = TapSyncEvent(
                device: "iPhone",
                peak_ms: peakMs,
                confidence: Double(audioLevel),
                event_type: "audio_peak"
            )
            tapEvents.append(event)
            print("🎤 Audio peak detected at \(peakMs)ms")
            return event
        }
        return nil
    }
    
    // MARK: - Watch側メソッド
    
    func setT0Watch(syncInfo: TimeSyncInfo, watchTimestamp: Double) {
        self.t0_phone = syncInfo.t0_phone
        // 注: t0_watch は最初の motion.timestamp で設定される
        self.wallclock_t0 = syncInfo.wallclock_iso
        
        print("📍 Watch: t0 received")
        print("   - t0_phone: \(syncInfo.t0_phone)")
        print("   - wallclock: \(syncInfo.wallclock_iso)")
        print("   - t0_watch will be set on first motion sample")
    }
    
    /// Watch側で最初のモーションタイムスタンプを設定（重要！）
    func setInitialMotionTimestamp(_ motionTimestamp: Double) {
        guard !hasSetInitialMotionTimestamp else { return }
        
        self.t0_watch = motionTimestamp
        self.hasSetInitialMotionTimestamp = true
        
        print("📍 Watch: t0_watch set from first motion sample")
        print("   - t0_watch: \(motionTimestamp)")
    }
    
    func detectIMUJerk(acceleration: (x: Double, y: Double, z: Double),
                       previousAcceleration: (x: Double, y: Double, z: Double)?,
                       timestamp: Double) -> TapSyncEvent? {
        guard let t0 = t0_watch, let prev = previousAcceleration else { return nil }
        
        let jerk = sqrt(
            pow(acceleration.x - prev.x, 2) +
            pow(acceleration.y - prev.y, 2) +
            pow(acceleration.z - prev.z, 2)
        )
        
        if jerk > 5.0 {
            let peakMs = Int64((timestamp - t0) * 1000)
            let confidence = min(jerk / 10.0, 1.0)
            
            let event = TapSyncEvent(
                device: "Watch",
                peak_ms: peakMs,
                confidence: confidence,
                event_type: "imu_jerk"
            )
            tapEvents.append(event)
            print("📳 IMU jerk detected at \(peakMs)ms (jerk: \(String(format: "%.2f", jerk)))")
            return event
        }
        return nil
    }
    
    // MARK: - 同期補正
    
    func calculateTapSyncCorrection() -> SyncCorrection? {
        let audioEvents = tapEvents.filter { $0.event_type == "audio_peak" }
        let imuEvents = tapEvents.filter { $0.event_type == "imu_jerk" }
        
        guard let audioEvent = audioEvents.last,
              let imuEvent = imuEvents.last else {
            print("⚠️ Insufficient events for tap sync")
            return nil
        }
        
        let delta = Double(audioEvent.peak_ms - imuEvent.peak_ms)
        let confidence = min(audioEvent.confidence, imuEvent.confidence)
        
        let correction = SyncCorrection(
            delta_ms: delta,
            method: "tap_sync",
            confidence: confidence,
            applied_at: ISO8601DateFormatter().string(from: Date())
        )
        
        corrections.append(correction)
        currentDelta = delta
        
        print("🔧 Tap sync correction: \(String(format: "%.2f", delta))ms (confidence: \(String(format: "%.2f", confidence)))")
        
        return correction
    }
    
    func calculateLinearDriftCorrection(dataPoints: [(x: Double, y: Double)]) -> SyncCorrection? {
        guard dataPoints.count >= 3 else {
            print("⚠️ Need at least 3 data points for linear correction")
            return nil
        }
        
        let n = Double(dataPoints.count)
        let sumX = dataPoints.reduce(0.0) { $0 + $1.x }
        let sumY = dataPoints.reduce(0.0) { $0 + $1.y }
        let sumXY = dataPoints.reduce(0.0) { $0 + $1.x * $1.y }
        let sumX2 = dataPoints.reduce(0.0) { $0 + $1.x * $1.x }
        
        let slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX)
        let intercept = (sumY - slope * sumX) / n
        
        let correction = SyncCorrection(
            delta_ms: intercept,
            method: "linear_drift",
            confidence: 0.8,
            applied_at: ISO8601DateFormatter().string(from: Date())
        )
        
        corrections.append(correction)
        currentDelta = intercept
        
        print("📐 Linear drift correction: \(String(format: "%.2f", intercept))ms (slope: \(String(format: "%.4f", slope)))")
        
        return correction
    }
    
    /// 相対時刻を取得（ms）
    func getRelativeTimeMs(currentTimestamp: Double, isWatch: Bool) -> Int64 {
        let t0 = isWatch ? (t0_watch ?? 0) : (t0_phone ?? 0)
        let relativeMs = Int64((currentTimestamp - t0) * 1000)
        return relativeMs + Int64(currentDelta)
    }
    
    /// リセット
    func reset() {
        t0_phone = nil
        t0_watch = nil
        wallclock_t0 = nil
        tapEvents.removeAll()
        corrections.removeAll()
        currentDelta = 0.0
        hasSetInitialMotionTimestamp = false
        print("🔄 SyncCoordinator reset")
    }
    
    /// デバッグ情報
    func debugInfo() -> String {
        return """
        === Sync Coordinator ===
        t0_phone: \(t0_phone.map { String($0) } ?? "nil")
        t0_watch: \(t0_watch.map { String($0) } ?? "nil")
        wallclock_t0: \(wallclock_t0 ?? "nil")
        current_delta: \(String(format: "%.2f", currentDelta))ms
        tap_events: \(tapEvents.count)
        corrections: \(corrections.count)
        has_initial_motion: \(hasSetInitialMotionTimestamp)
        """
    }
}
