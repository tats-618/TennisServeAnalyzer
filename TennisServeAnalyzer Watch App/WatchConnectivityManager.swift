//
//  WatchConnectivityManager.swift
//  TennisServeAnalyzer Watch App
//
//  Handles communication with iPhone
//

import WatchConnectivity
import Foundation

class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()
    
    @Published var session: WCSession?
    
    // Callbacks for commands from iPhone
    var onStartRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?
    
    private override init() {
        super.init()
        
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session
            
            print("⌚ WatchConnectivity activated on Watch")
        }
    }
    
    // MARK: - Time Sync
    func requestTimeSyncFromPhone(completion: @escaping (Bool) -> Void) {
        guard let session = session, session.isReachable else {
            print("⚠️ iPhone not reachable for time sync request")
            completion(false)
            return
        }
        
        let message: [String: Any] = [
            "type": "requestTimeSync"
        ]
        
        // Timeout handling (3 seconds)
        var didComplete = false
        let timeoutItem = DispatchWorkItem {
            if !didComplete {
                print("⚠️ Time sync request timeout after 3 seconds")
                completion(false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: timeoutItem)
        
        session.sendMessage(message, replyHandler: { reply in
            guard !didComplete else { return }
            didComplete = true
            timeoutItem.cancel()
            
            // Process response from iPhone
            if let t0Phone = reply["t0_phone"] as? Double,
               let _ = reply["wallclock_iso"] as? String {
                
                print("✅ Time sync received: t0=\(t0Phone)")
                completion(true)
            } else {
                completion(false)
            }
        }) { error in
            guard !didComplete else { return }
            didComplete = true
            timeoutItem.cancel()
            print("❌ Error requesting time sync: \(error.localizedDescription)")
            completion(false)
        }
    }
    
    // MARK: - Send Data to iPhone
    func sendBatchData(_ batch: [ServeSample], flags: [String]) {
        guard let session = session, session.isReachable else {
            print("⚠️ iPhone not reachable for batch send")
            return
        }
        
        // Check for delay (oldest sample > 1.2s ago)
        var batchFlags = flags
        if let oldest = batch.first {
            let currentMs = Int64(Date().timeIntervalSince1970 * 1000)
            if currentMs - oldest.monotonic_ms > 1200 {
                batchFlags.append("delayed_batch")
            }
        }
        
        do {
            let encoder = JSONEncoder()
            let batchData = try encoder.encode(batch)
            
            // Send as data message for efficiency
            session.sendMessageData(batchData, replyHandler: nil) { error in
                print("❌ Batch send failed: \(error.localizedDescription)")
            }
            
            if batch.count >= 50 {
                print("📤 Sent batch: \(batch.count) samples")
            }
        } catch {
            print("❌ Failed to encode batch data: \(error)")
        }
    }
    
    func sendRealtimeData(_ sample: ServeSample) {
        guard let session = session, session.isReachable else {
            return
        }
        
        let message: [String: Any] = [
            "type": "realtimeData",
            "timestamp": sample.wallclock_iso,
            "accel_x": sample.ax,
            "accel_y": sample.ay,
            "accel_z": sample.az,
            "gyro_x": sample.gx,
            "gyro_y": sample.gy,
            "gyro_z": sample.gz
        ]
        
        session.sendMessage(message, replyHandler: nil) { error in
            // Silently fail for realtime data
        }
    }
    
    func sendAnalysisResult(_ analysis: ServeAnalysis) {
        guard let session = session, session.isReachable else {
            print("⚠️ iPhone not reachable")
            return
        }
        
        var message: [String: Any] = [
            "type": "analysisResult",
            "maxAcceleration": analysis.maxAcceleration,
            "maxAngularVelocity": analysis.maxAngularVelocity,
            "estimatedSwingSpeed": analysis.estimatedSwingSpeed,
            "duration": analysis.duration,
            "recordedAt": analysis.recordedAt.timeIntervalSince1970
        ]
        
        // NTP同期データを追加
        if let impactTimestamp = analysis.impactTimestamp {
            message["impactTimestamp"] = impactTimestamp
        }
        if let yaw = analysis.impactRacketYaw {
            message["impactRacketYaw"] = yaw
        }
        if let pitch = analysis.impactRacketPitch {
            message["impactRacketPitch"] = pitch
        }
        if let peakR = analysis.swingPeakPositionR {
            message["swingPeakPositionR"] = peakR
        }
        
        session.sendMessage(message, replyHandler: nil) { error in
            print("❌ Error sending analysis result: \(error.localizedDescription)")
        }
    }
}

// MARK: - WCSessionDelegate
extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("❌ WCSession activation failed: \(error.localizedDescription)")
        } else {
            print("✅ WCSession activated successfully on Watch")
            print("   - Activation state: \(activationState.rawValue)")
            print("   - iOS app installed: \(session.isCompanionAppInstalled)")
        }
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        print("📨 Received message from iPhone: \(message.keys.joined(separator: ", "))")
        
        // Handle commands from iPhone
        if let command = message["command"] as? String {
            DispatchQueue.main.async { [weak self] in
                switch command {
                case "startRecording":
                    print("▶️ Received START command from iPhone")
                    self?.onStartRecording?()
                    
                case "stopRecording":
                    print("⏹ Received STOP command from iPhone")
                    self?.onStopRecording?()
                    
                default:
                    print("⚠️ Unknown command: \(command)")
                }
            }
        }
        
        // Handle time sync
        if message["type"] as? String == "timeSync" {
            print("⏱ Received time sync from iPhone")
        }
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        print("📨 Received message with reply handler from iPhone")
        
        // NTP同期リクエストの処理
        if let t1 = message["ntpSyncT1"] as? Double {
            let t2 = ProcessInfo.processInfo.systemUptime  // Watch受信時刻
            
            // 最小限の処理でt3を取得（レスポンス直前）
            let t3 = ProcessInfo.processInfo.systemUptime  // Watch返信時刻
            
            let response: [String: Any] = [
                "t1": t1,
                "t2": t2,
                "t3": t3
            ]
            
            replyHandler(response)
            print("✅ Sent NTP sync response to iPhone")
            print("   t1 (echoed): \(String(format: "%.6f", t1))")
            print("   t2 (recv): \(String(format: "%.6f", t2))")
            print("   t3 (send): \(String(format: "%.6f", t3))")
            return
        }
        
        // Handle commands with reply
        if let command = message["command"] as? String {
            DispatchQueue.main.async { [weak self] in
                switch command {
                case "startRecording":
                    print("▶️ Received START command from iPhone")
                    self?.onStartRecording?()
                    
                case "stopRecording":
                    print("⏹ Received STOP command from iPhone")
                    self?.onStopRecording?()
                    
                default:
                    print("⚠️ Unknown command: \(command)")
                }
            }
        }
        
        // Handle time sync
        if message["type"] as? String == "timeSync" {
            print("⏱ Received time sync from iPhone")
        }
        
        // Default reply
        replyHandler(["status": "ok"])
    }
}
