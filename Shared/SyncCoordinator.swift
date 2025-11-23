//
//  SyncCoordinator.swift
//  TennisServeAnalyzer
//
//  P1: 時刻同期マネージャー（NTP方式対応）
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

/// NTP同期リクエスト
struct NTPSyncRequest: Codable {
    let t1: Double  // iOS送信時刻
}

/// NTP同期レスポンス
struct NTPSyncResponse: Codable {
    let t1: Double  // iOS送信時刻（エコーバック）
    let t2: Double  // Watch受信時刻
    let t3: Double  // Watch返信時刻
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
    
    // MARK: - NTP-like Time Sync
    
    /// iOS-Watch間の時刻オフセット（秒）
    /// Offset = Watch時刻 - iOS時刻
    private(set) var timeOffset: Double = 0.0
    
    /// 同期品質（RTT）
    private(set) var syncQuality: Double = 0.0
    
    /// 同期完了フラグ
    private(set) var isSyncComplete: Bool = false
    
    /// 同期試行回数
    private var syncAttempts: Int = 0
    private let maxSyncAttempts: Int = 5
    private let maxAcceptableRTT: Double = 0.100  // 100ms
    
    /// 同期進行中フラグ
    private var isSyncInProgress: Bool = false
    
    /// 同期コールバック
    private var syncCompletionHandlers: [(Bool) -> Void] = []
    
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
    
    // MARK: - NTP Time Sync (iOS側)
    
    /// NTP方式の時刻同期を開始
    /// - Parameter completion: 同期完了時のコールバック（成功/失敗）
    func performNTPSync(sendMessageHandler: @escaping (NTPSyncRequest, @escaping (NTPSyncResponse?) -> Void) -> Void, completion: @escaping (Bool) -> Void) {
        guard !isSyncInProgress else {
            print("⚠️ NTP sync already in progress")
            syncCompletionHandlers.append(completion)
            return
        }
        
        isSyncInProgress = true
        syncCompletionHandlers.append(completion)
        syncAttempts = 0
        
        attemptNTPSync(sendMessageHandler: sendMessageHandler)
    }
    
    private func attemptNTPSync(sendMessageHandler: @escaping (NTPSyncRequest, @escaping (NTPSyncResponse?) -> Void) -> Void) {
        syncAttempts += 1
        
        if syncAttempts > maxSyncAttempts {
            print("❌ NTP sync failed after \(maxSyncAttempts) attempts")
            finishSync(success: false)
            return
        }
        
        // t1: iOS送信時刻
        let t1 = ProcessInfo.processInfo.systemUptime
        let request = NTPSyncRequest(t1: t1)
        
        print("📤 NTP sync attempt \(syncAttempts): t1=\(String(format: "%.6f", t1))")
        
        // Watchへ送信してレスポンスを待つ
        sendMessageHandler(request) { [weak self] response in
            guard let self = self, let response = response else {
                print("❌ NTP sync: no response")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.attemptNTPSync(sendMessageHandler: sendMessageHandler)
                }
                return
            }
            
            // t4: iOS受信時刻
            let t4 = ProcessInfo.processInfo.systemUptime
            
            self.processNTPResponse(response: response, t4: t4, sendMessageHandler: sendMessageHandler)
        }
    }
    
    private func processNTPResponse(response: NTPSyncResponse, t4: Double, sendMessageHandler: @escaping (NTPSyncRequest, @escaping (NTPSyncResponse?) -> Void) -> Void) {
        let t1 = response.t1
        let t2 = response.t2
        let t3 = response.t3
        
        // RTT = (t4 - t1) - (t3 - t2)
        let rtt = (t4 - t1) - (t3 - t2)
        
        // Offset = ((t2 - t1) + (t3 - t4)) / 2
        let offset = ((t2 - t1) + (t3 - t4)) / 2.0
        
        print("📊 NTP sync result:")
        print("   t1 (iOS send):  \(String(format: "%.6f", t1))")
        print("   t2 (Watch recv): \(String(format: "%.6f", t2))")
        print("   t3 (Watch send): \(String(format: "%.6f", t3))")
        print("   t4 (iOS recv):   \(String(format: "%.6f", t4))")
        print("   RTT: \(String(format: "%.3f", rtt * 1000))ms")
        print("   Offset: \(String(format: "%.3f", offset * 1000))ms")
        
        // RTT品質チェック
        if rtt > maxAcceptableRTT {
            print("⚠️ RTT too high (\(String(format: "%.1f", rtt * 1000))ms), retrying...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.attemptNTPSync(sendMessageHandler: sendMessageHandler)
            }
            return
        }
        
        // 同期成功
        self.timeOffset = offset
        self.syncQuality = rtt
        self.isSyncComplete = true
        
        print("✅ NTP sync complete: offset=\(String(format: "%.3f", offset * 1000))ms, quality=\(String(format: "%.1f", rtt * 1000))ms")
        
        finishSync(success: true)
    }
    
    private func finishSync(success: Bool) {
        isSyncInProgress = false
        
        let handlers = syncCompletionHandlers
        syncCompletionHandlers.removeAll()
        
        for handler in handlers {
            handler(success)
        }
    }
    
    /// WatchタイムスタンプをiOSタイムスタンプに変換
    /// - Parameter watchTime: Watch側のsystemUptime
    /// - Returns: iOS側のsystemUptimeに変換された時刻
    func convertWatchTimeToiOS(_ watchTime: Double) -> Double? {
        guard isSyncComplete else { return nil }
        return watchTime - timeOffset
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
        
        // NTP同期リセット
        timeOffset = 0.0
        syncQuality = 0.0
        isSyncComplete = false
        syncAttempts = 0
        isSyncInProgress = false
        syncCompletionHandlers.removeAll()
        
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
        --- NTP Sync ---
        is_complete: \(isSyncComplete)
        time_offset: \(String(format: "%.3f", timeOffset * 1000))ms
        sync_quality: \(String(format: "%.1f", syncQuality * 1000))ms RTT
        """
    }
}
