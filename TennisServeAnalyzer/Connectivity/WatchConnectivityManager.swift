//
//  WatchConnectivityManager.swift
//  TennisServeAnalyzer (iOS)
//
//  Receives IMU data from Apple Watch
//  Updated: Optimized for 200Hz data reception + NTP Time Sync
//

import Foundation
import WatchConnectivity
import Combine

// MARK: - Watch Data Models
struct WatchIMUData {
    let timestamp: Double
    let monotonicMs: Int64
    let acceleration: (x: Double, y: Double, z: Double)
    let gyroscope: (x: Double, y: Double, z: Double)
    
    // Convert to ServeSample
    func toServeSample() -> ServeSample {
        return ServeSample(
            timestamp: Date(timeIntervalSince1970: timestamp),
            monotonicMs: monotonicMs,
            acceleration: acceleration,
            gyroscope: gyroscope
        )
    }
}

// MARK: - iOS WatchConnectivity Manager
class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()
    
    // MARK: Properties
    @Published var isWatchConnected: Bool = false
    @Published var isWatchReachable: Bool = false
    @Published var lastReceivedTimestamp: Date?
    @Published var receivedSamplesCount: Int = 0
    @Published var effectiveReceiveRate: Double = 0.0
    
    // Callbacks
    var onIMUDataReceived: ((ServeSample) -> Void)?
    var onBatchDataReceived: (([ServeSample]) -> Void)?
    var onAnalysisResultReceived: ((ServeAnalysis) -> Void)?
    
    private var session: WCSession?
    
    // 並行処理用キュー（200Hz対応）
    private let processingQueue = DispatchQueue(
        label: "com.tennisanalyzer.imuprocessing",
        qos: .userInitiated,
        attributes: .concurrent
    )
    
    // 受信レート計測
    private var lastReceiveTime: TimeInterval = 0
    private var receiveIntervals: [TimeInterval] = []
    private var rateCheckTimer: Timer?
    
    /// 同期コーディネーター
    private let syncCoordinator = SyncCoordinator.shared
    
    // MARK: - Initialization
    private override init() {
        super.init()
        
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session
            
            print("📱 iOS WatchConnectivityManager initialized (200Hz optimized + NTP Sync)")
            
            // 受信レート監視を開始
            startRateMonitoring()
        } else {
            print("⚠️ WatchConnectivity not supported on this device")
        }
    }
    
    // MARK: - Rate Monitoring
    private func startRateMonitoring() {
        rateCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateEffectiveReceiveRate()
        }
    }
    
    private func updateEffectiveReceiveRate() {
        guard !receiveIntervals.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.effectiveReceiveRate = 0.0
            }
            return
        }
        
        let avgInterval = receiveIntervals.reduce(0, +) / Double(receiveIntervals.count)
        let effectiveHz = avgInterval > 0 ? 1.0 / avgInterval : 0
        
        DispatchQueue.main.async { [weak self] in
            self?.effectiveReceiveRate = effectiveHz
        }
        
        print("📊 iPhone receive rate: \(String(format: "%.1f", effectiveHz)) samples/sec")
    }
    
    // MARK: - NTP Time Sync
    
    /// NTP方式の時刻同期を開始
    func startNTPSync(completion: @escaping (Bool) -> Void) {
        guard let session = session, session.isReachable else {
            print("⚠️ Watch not reachable for NTP sync")
            completion(false)
            return
        }
        
        print("🕒 Starting NTP time sync with Watch...")
        
        syncCoordinator.performNTPSync(sendMessageHandler: { [weak self] request, responseHandler in
            guard let self = self, let session = self.session, session.isReachable else {
                responseHandler(nil)
                return
            }
            
            let message: [String: Any] = [
                "ntpSyncT1": request.t1
            ]
            
            // タイムアウト処理
            var didRespond = false
            let timeoutItem = DispatchWorkItem {
                if !didRespond {
                    print("⚠️ NTP sync timeout")
                    responseHandler(nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: timeoutItem)
            
            session.sendMessage(message, replyHandler: { reply in
                guard !didRespond else { return }
                didRespond = true
                timeoutItem.cancel()
                
                if let t1 = reply["t1"] as? Double,
                   let t2 = reply["t2"] as? Double,
                   let t3 = reply["t3"] as? Double {
                    let response = NTPSyncResponse(t1: t1, t2: t2, t3: t3)
                    responseHandler(response)
                } else {
                    print("⚠️ Invalid NTP response format")
                    responseHandler(nil)
                }
            }) { error in
                guard !didRespond else { return }
                didRespond = true
                timeoutItem.cancel()
                print("❌ NTP sync message failed: \(error.localizedDescription)")
                responseHandler(nil)
            }
        }, completion: completion)
    }
    
    // MARK: - Send Commands to Watch
    
    /// Start recording on Watch
    func startWatchRecording() {
        guard let session = session, session.isReachable else {
            print("⚠️ Watch not reachable, cannot start recording")
            return
        }
        
        let message: [String: Any] = [
            "command": "startRecording",
            "timestamp": Date().timeIntervalSince1970
        ]
        
        print("📤 Sending START command to Watch")
        
        session.sendMessage(message, replyHandler: { reply in
            print("✅ Watch replied to START: \(reply)")
        }) { error in
            print("❌ Failed to send START to Watch: \(error.localizedDescription)")
        }
    }
    
    /// Stop recording on Watch
    func stopWatchRecording() {
        guard let session = session, session.isReachable else {
            print("⚠️ Watch not reachable, cannot stop recording")
            return
        }
        
        let message: [String: Any] = [
            "command": "stopRecording",
            "timestamp": Date().timeIntervalSince1970
        ]
        
        print("📤 Sending STOP command to Watch")
        
        session.sendMessage(message, replyHandler: { reply in
            print("✅ Watch replied to STOP: \(reply)")
        }) { error in
            print("❌ Failed to send STOP to Watch: \(error.localizedDescription)")
        }
    }
    
    /// Send time sync to Watch
    func sendTimeSync() {
        guard let session = session, session.isReachable else {
            print("⚠️ Watch not reachable for time sync")
            return
        }
        
        let t0Phone = Date().timeIntervalSinceReferenceDate
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wallclockISO = formatter.string(from: Date())
        
        let message: [String: Any] = [
            "type": "timeSync",
            "t0_phone": t0Phone,
            "wallclock_iso": wallclockISO
        ]
        
        print("⏱ Sending time sync to Watch")
        
        session.sendMessage(message, replyHandler: nil) { error in
            print("❌ Time sync failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Process Received Data
    
    private func processRealtimeData(_ message: [String: Any]) {
        guard let timestamp = message["timestamp"] as? Double,
              let accelX = message["accel_x"] as? Double,
              let accelY = message["accel_y"] as? Double,
              let accelZ = message["accel_z"] as? Double,
              let gyroX = message["gyro_x"] as? Double,
              let gyroY = message["gyro_y"] as? Double,
              let gyroZ = message["gyro_z"] as? Double else {
            print("⚠️ Invalid realtime data format")
            return
        }
        
        let monotonicMs = Int64(timestamp * 1000)
        
        let sample = ServeSample(
            timestamp: Date(timeIntervalSince1970: timestamp),
            monotonicMs: monotonicMs,
            acceleration: (accelX, accelY, accelZ),
            gyroscope: (gyroX, gyroY, gyroZ)
        )
        
        trackReceiveRate()
        
        DispatchQueue.main.async { [weak self] in
            self?.lastReceivedTimestamp = Date()
            self?.receivedSamplesCount += 1
            self?.onIMUDataReceived?(sample)
        }
        
        if receivedSamplesCount % 100 == 0 {
            print("📊 Received \(receivedSamplesCount) IMU samples from Watch")
        }
    }
    
    private func processBatchData(_ data: Data, metadata: [String: Any]) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                let decoder = JSONDecoder()
                let samples = try decoder.decode([ServeSample].self, from: data)
                
                print("📦 Received batch: \(samples.count) samples")
                
                self.trackReceiveRate()
                
                DispatchQueue.main.async {
                    self.receivedSamplesCount += samples.count
                    self.onBatchDataReceived?(samples)
                }
            } catch {
                print("❌ Failed to decode batch data: \(error)")
            }
        }
    }
    
    private func trackReceiveRate() {
        let currentTime = Date().timeIntervalSinceReferenceDate
        
        if lastReceiveTime > 0 {
            let interval = currentTime - lastReceiveTime
            receiveIntervals.append(interval)
            
            if receiveIntervals.count > 100 {
                receiveIntervals.removeFirst()
            }
        }
        
        lastReceiveTime = currentTime
    }
    
    private func processAnalysisResult(_ message: [String: Any]) {
        guard let maxAccel = message["maxAcceleration"] as? Double,
              let maxGyro = message["maxAngularVelocity"] as? Double,
              let swingSpeed = message["estimatedSwingSpeed"] as? Double,
              let duration = message["duration"] as? TimeInterval,
              let recordedAt = message["recordedAt"] as? TimeInterval else {
            print("⚠️ Invalid analysis result format")
            return
        }
        
        // ★ NTP同期データを取得
        let impactTimestamp = message["impactTimestamp"] as? TimeInterval
        let impactRacketYaw = message["impactRacketYaw"] as? Double
        let impactRacketPitch = message["impactRacketPitch"] as? Double
        let swingPeakPositionR = message["swingPeakPositionR"] as? Double
        
        let analysis = ServeAnalysis(
            maxAcceleration: maxAccel,
            maxAngularVelocity: maxGyro,
            estimatedSwingSpeed: swingSpeed,
            duration: duration,
            recordedAt: Date(timeIntervalSince1970: recordedAt),
            impactTimestamp: impactTimestamp,
            impactRacketYaw: impactRacketYaw,
            impactRacketPitch: impactRacketPitch,
            swingPeakPositionR: swingPeakPositionR
        )
        
        print("📊 Watch analysis result received")
        if let impactTime = impactTimestamp {
            print("   Impact timestamp: \(String(format: "%.6f", impactTime))s")
        }
        if let yaw = impactRacketYaw {
            print("   Racket yaw: \(String(format: "%.1f", yaw))°")
        }
        if let pitch = impactRacketPitch {
            print("   Racket pitch: \(String(format: "%.1f", pitch))°")
        }
        if let peakR = swingPeakPositionR {
            print("   Peak position (r): \(String(format: "%.3f", peakR))")
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.onAnalysisResultReceived?(analysis)
        }
    }
    
    // MARK: - Reset
    func reset() {
        print("🔄 Resetting WatchConnectivityManager")
        receivedSamplesCount = 0
        lastReceivedTimestamp = nil
        receiveIntervals.removeAll()
        effectiveReceiveRate = 0.0
    }
    
    deinit {
        rateCheckTimer?.invalidate()
    }
}

// MARK: - WCSessionDelegate
extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            if let error = error {
                print("❌ WCSession activation failed: \(error.localizedDescription)")
                self?.isWatchConnected = false
            } else {
                print("✅ WCSession activated on iOS")
                print("   - Activation state: \(activationState.rawValue)")
                self?.isWatchConnected = (activationState == .activated)
                
                if session.isPaired {
                    print("✅ Watch is paired")
                }
                if session.isWatchAppInstalled {
                    print("✅ Watch app is installed")
                }
                
                // タイムシンクを送信
                self?.sendTimeSync()
            }
        }
    }
    
    func sessionDidBecomeInactive(_ session: WCSession) {
        print("⚠️ WCSession became inactive")
        DispatchQueue.main.async { [weak self] in
            self?.isWatchConnected = false
        }
    }
    
    func sessionDidDeactivate(_ session: WCSession) {
        print("⚠️ WCSession deactivated")
        session.activate()
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.isWatchReachable = session.isReachable
            print("📡 Watch reachability: \(session.isReachable)")
        }
    }
    
    // MARK: - Message Handlers
    
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        print("📨 Received message from Watch: \(message.keys.joined(separator: ", "))")
        
        guard let messageType = message["type"] as? String else {
            print("⚠️ Message missing 'type' field")
            return
        }
        
        switch messageType {
        case "realtimeData":
            processRealtimeData(message)
            
        case "analysisResult":
            processAnalysisResult(message)
            
        case "requestTimeSync":
            // Watch requesting time sync
            sendTimeSync()
            
        case "reset":
            reset()
            
        default:
            print("⚠️ Unknown message type: \(messageType)")
        }
    }
    
    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        print("📦 Received data message from Watch (\(messageData.count) bytes)")
        processBatchData(messageData, metadata: [:])
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        print("📨 Received message with reply handler from Watch")
        
        // Handle time sync requests
        if message["type"] as? String == "requestTimeSync" {
            let t0Phone = Date().timeIntervalSinceReferenceDate
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let wallclockISO = formatter.string(from: Date())
            
            let reply: [String: Any] = [
                "t0_phone": t0Phone,
                "wallclock_iso": wallclockISO
            ]
            
            replyHandler(reply)
            print("✅ Sent time sync reply to Watch")
        } else {
            replyHandler(["status": "ok"])
        }
    }
}
