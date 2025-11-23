// ーーーーー IMU Only Impact Detection + Normalized Efficiency Analysis + HealthKit Workout ーーーーー
//
//  ServeAnalyzer.swift
//  TennisServeAnalyzer Watch App
//
//  🚀 Audio機能を全削除し、IMUの衝撃検知のみで実装
//  📊 スイング効率分析: 構え(Start)〜インパクト(End)で正規化 (0.0~1.0)
//  🎯 スイング速度(Gyro)と衝撃(Accel Jerk)を監視してインパクトを特定
//  🔧 NTP同期: インパクト時のタイムスタンプ、ラケット角度、ピーク位置をiOSへ送信
//  🏋️ HealthKit Workout: バックグラウンド継続のためワークアウトセッション実装
//

import Foundation
import CoreMotion
import Combine
import simd
import WatchKit
import HealthKit

final class ServeAnalyzer: NSObject, ObservableObject {
    // MARK: - Public (UI Bindings)
    @Published var collectionState: DataCollectionState = .idle
    @Published var isRecording: Bool = false
    @Published var currentSampleCount: Int = 0
    @Published var effectiveSampleRate: Double = 0.0

    // ステータス表示
    @Published var statusHeader: String = "⏸ Idle"
    @Published var statusDetail: String = "起動しました"
    @Published var samplingStatus: String = "IMU 200Hz 設定済み"
    @Published var connectionStatusText: String = "未接続"

    // キャリブ進行状態
    enum CalibStage { case idle, levelPrompt, levelDone, dirPrompt, dirDone, ready }
    @Published var calibStage: CalibStage = .idle
    @Published var hasLevelCalib: Bool = false
    @Published var hasDirCalib: Bool = false

    // 面角表示
    @Published var lastFaceYawDeg: Float = 0.0     // Roll
    @Published var lastFacePitchDeg: Float = 0.0   // Pitch
    @Published var lastFaceAdvice: String = ""

    // ★ Peak Position (r) 表示用
    @Published var lastPeakPositionR: Double = 0.0
    @Published var lastPeakEvalText: String = ""

    // MARK: - HealthKit Workout
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    
    // MARK: - Internals
    private let watchManager = WatchConnectivityManager.shared

    // IMU
    private let motionManager = CMMotionManager()
    private let imuHz: Double = 200.0
    private var lastLogTimestamp: TimeInterval = 0

    // キャリブ用変数
    private var R_calib: simd_float3x3? = nil
    private var yAxisWorld_calib: simd_float3? = nil
    private var faceNormal0World: simd_float3? = nil
    private let n_device = simd_float3(0, 0, 1)

    // 姿勢バッファ
    private struct AttSample {
        let t: TimeInterval
        let R: simd_float3x3
        let gyroMag: Double    // 角速度の大きさ (rad/s)
        let userAccelMag: Double // ユーザー加速度の大きさ (G)
    }
    private var attBuffer: [AttSample] = []
    private let attBufferMax = 800

    // 時間変換用
    private var timebaseInfo = mach_timebase_info_data_t()
    private var startTime: Date?

    // MARK: - Impact Detection Logic (IMU Based)
    
    // デバウンス
    private let hitDebounceTime: TimeInterval = 1.0
    private var lastHitTime: TimeInterval = 0
    
    // 閾値設定
    private let swingGateThreshold: Double = 3.0  // rad/s
    private let impactShockThreshold: Double = 2.0 // G
    
    // 前回の加速度（変化量計算用）
    private var lastUserAccelMag: Double = 0.0

    // ★ NTP同期用: インパクト時のデータ保存
    private var currentImpactTimestamp: TimeInterval?
    private var currentPeakPositionR: Double = 0.0

    // MARK: - Init
    override init() {
        super.init()
        print("⌚ ServeAnalyzer init (IMU Impact + Normalized Analysis + NTP Sync + HealthKit)")
        connectionStatusText = (watchManager.session?.isReachable ?? false) ? "iPhone接続" : "未接続"
        requestHealthKitAuthorization()
        startStatusTimer()
    }

    // MARK: - HealthKit Authorization
    private func requestHealthKitAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("❌ HealthKit not available on this device")
            return
        }
        
        let typesToShare: Set<HKSampleType> = [
            HKObjectType.workoutType()
        ]
        
        let typesToRead: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
        ]
        
        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { success, error in
            if success {
                print("✅ HealthKit authorization granted")
            } else {
                print("❌ HealthKit authorization failed: \(error?.localizedDescription ?? "unknown")")
            }
        }
    }

    // MARK: - Workout Session Management
    
    /// ワークアウトセッション開始
    private func startWorkoutSession() {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("❌ HealthKit not available")
            return
        }
        
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .tennis
        configuration.locationType = .outdoor
        
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            
            session.delegate = self
            builder.delegate = self
            
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            
            self.workoutSession = session
            self.workoutBuilder = builder
            
            let startDate = Date()
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { success, error in
                if success {
                    print("🏋️ Workout session started successfully")
                } else {
                    print("❌ Failed to start workout builder: \(error?.localizedDescription ?? "unknown")")
                }
            }
            
        } catch {
            print("❌ Failed to create workout session: \(error.localizedDescription)")
        }
    }
    
    /// ワークアウトセッション終了
    private func stopWorkoutSession() {
        guard let session = workoutSession, let builder = workoutBuilder else {
            print("⚠️ No active workout session to stop")
            return
        }
        
        session.end()
        
        builder.endCollection(withEnd: Date()) { success, error in
            if success {
                builder.finishWorkout { workout, error in
                    if let workout = workout {
                        print("✅ Workout saved: duration=\(workout.duration)s")
                    } else {
                        print("❌ Failed to save workout: \(error?.localizedDescription ?? "unknown")")
                    }
                }
            } else {
                print("❌ Failed to end workout collection: \(error?.localizedDescription ?? "unknown")")
            }
        }
        
        self.workoutSession = nil
        self.workoutBuilder = nil
    }

    // MARK: - Status / Timers
    private func startStatusTimer() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tickStatus()
        }
    }

    private func tickStatus() {
        connectionStatusText = (watchManager.session?.isReachable ?? false) ? "iPhone接続" : "未接続"

        let rec = isRecording ? "📊 Recording" : "⏸ Idle"
        var detail = "IMU衝撃検知モード"

        switch calibStage {
        case .idle:        detail += " / キャリブ未開始"
        case .levelPrompt: detail += " / 『水平』置きで登録待ち"
        case .levelDone:   detail += " / 水平OK"
        case .dirPrompt:   detail += " / 『方向』立て置きで登録待ち"
        case .dirDone:     detail += " / 方向OK"
        case .ready:       detail += " / 準備完了"
        }

        statusHeader = rec
        statusDetail = detail

        if motionManager.isDeviceMotionActive {
            samplingStatus = String(format: "IMU 稼働中: %.0f Hz", effectiveSampleRate)
        } else {
            samplingStatus = String(format: "IMU %.0fHz 設定済み", imuHz)
        }
    }

    // MARK: - Recording Control
    func startRecording() {
        guard !isRecording else { return }
        print("🎬 Starting recording...")

        // 🏋️ ワークアウトセッション開始
        startWorkoutSession()
        
        startTime = Date()
        lastHitTime = 0
        lastUserAccelMag = 0
        lastFaceYawDeg = 0
        lastFacePitchDeg = 0
        lastFaceAdvice = ""
        lastPeakPositionR = 0.0
        lastPeakEvalText = ""
        
        // NTP同期用データリセット
        currentImpactTimestamp = nil
        currentPeakPositionR = 0.0

        isRecording = true
        collectionState = DataCollectionState.collecting
        statusHeader = "📊 Recording"
        print("✅ Recording started (IMU Only + NTP Sync + Workout)")
    }

    func stopRecording() {
        guard isRecording else { return }
        print("⏹ Stopping recording...")

        isRecording = false
        collectionState = DataCollectionState.completed

        let duration = startTime.map { -$0.timeIntervalSinceNow } ?? 0
        print("✅ Recording stopped (elapsed: \(String(format: "%.1f", duration))s)")
        statusHeader = "⏹ Stopped"
        
        // インパクトデータをiOSへ送信
        sendAnalysisToiOS()
        
        // 🏋️ ワークアウトセッション終了
        stopWorkoutSession()
    }

    // MARK: - IMU Lifecyle
    private func ensureIMUStarted() {
        guard motionManager.isDeviceMotionAvailable else {
            statusDetail = "❌ Motion NOT available"
            return
        }
        if !motionManager.isDeviceMotionActive {
            motionManager.deviceMotionUpdateInterval = 1.0 / imuHz
            motionManager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] dm, _ in
                guard let self = self, let dm = dm else { return }
                self.processDeviceMotion(dm)
            }
            effectiveSampleRate = imuHz
            print("✅ IMU started @ \(imuHz) Hz")
        }
    }
    
    // MARK: - IMU Processing Loop
    private func processDeviceMotion(_ dm: CMDeviceMotion) {
        let R = attitudeToR(dm.attitude)
        let t = dm.timestamp
        
        let rx = dm.rotationRate.x
        let ry = dm.rotationRate.y
        let rz = dm.rotationRate.z
        let gyroMag = sqrt(rx*rx + ry*ry + rz*rz)
        
        let ax = dm.userAcceleration.x
        let ay = dm.userAcceleration.y
        let az = dm.userAcceleration.z
        let userAccelMag = sqrt(ax*ax + ay*ay + az*az)
        
        attBuffer.append(.init(t: t, R: R, gyroMag: gyroMag, userAccelMag: userAccelMag))
        if attBuffer.count > attBufferMax {
            attBuffer.removeFirst(attBuffer.count - attBufferMax)
        }
        
        if isRecording {
            detectImpactFromMotion(t: t, gyroMag: gyroMag, userAccelMag: userAccelMag)
            
            if t - lastLogTimestamp > 0.005 {
                lastLogTimestamp = t
                let tMs = Int64(t * 1000)
                if let angles = calculateFaceAngles(from: R) {
                    let deltaAccel = abs(userAccelMag - lastUserAccelMag)
                    print(String(format: "%lldms | スイング速度:%.1f | 加速度（G）:%.1f | 衝撃:%.1f | 左右:%.1f 上下:%.1f",
                                 tMs, gyroMag, userAccelMag, deltaAccel, angles.roll, angles.pitch))
                }
            }
        }
        
        lastUserAccelMag = userAccelMag
    }
    
    /// 衝撃検知によるヒット判定
    private func detectImpactFromMotion(t: TimeInterval, gyroMag: Double, userAccelMag: Double) {
        if t - lastHitTime < hitDebounceTime { return }
        
        let lookBackWindow = 0.2
        let maxRecentGyro = attBuffer
            .filter { $0.t >= t - lookBackWindow }
            .map { $0.gyroMag }
            .max() ?? gyroMag
        
        if maxRecentGyro < swingGateThreshold { return }
        
        let deltaAccel = abs(userAccelMag - lastUserAccelMag)
        
        if deltaAccel > impactShockThreshold {
            lastHitTime = t
            
            if let bestSample = findBestImpactSample(triggerTime: t),
               let angles = calculateFaceAngles(from: bestSample.R) {
                
                DispatchQueue.main.async { [weak self] in
                    self?.lastFaceYawDeg = angles.roll
                    self?.lastFacePitchDeg = angles.pitch
                    WKInterfaceDevice.current().play(.success)
                }
                
                let triggerMs = Int64(t * 1000)
                let bestMs = Int64(bestSample.t * 1000)
                
                // ★ NTP同期用: インパクトタイムスタンプを保存
                currentImpactTimestamp = bestSample.t
                
                print("\n🔥🔥🔥 IMPACT DETECTED (IMU) 🔥🔥🔥")
                print(String(format: "🎯 HIT @ %lldms (Trig:%lld) | Gyro=%.1f (MaxRecent:%.1f) | ΔAcc=%.1f | 左右=%.1f°, 上下=%.1f°",
                             bestMs, triggerMs, bestSample.gyroMag, maxRecentGyro, deltaAccel, angles.roll, angles.pitch))
                
                analyzeSwingEfficiency(atHitTime: bestSample.t)
                
                print("--------------------------------------\n")
                
            } else {
                print("⚠️ Impact detected but history unavailable")
            }
        }
    }
    
    /// トリガー時刻の周辺から、最大角速度の瞬間を探す
    private func findBestImpactSample(triggerTime: TimeInterval) -> AttSample? {
        let window = 0.1
        let candidates = attBuffer.filter { abs($0.t - triggerTime) <= window }
        
        guard let maxGyroSample = candidates.max(by: { $0.gyroMag < $1.gyroMag }) else {
            return nil
        }
        
        let targetTime = maxGyroSample.t + 0.02
        return attBuffer.min(by: { abs($0.t - targetTime) < abs($1.t - targetTime) })
    }

    // MARK: - ★ Swing Efficiency Analysis Logic (Normalized v2)
    private func analyzeSwingEfficiency(atHitTime: TimeInterval) {
        
        let endTime = atHitTime
        
        let searchStartWindow = atHitTime - 3.0
        let searchEndWindow   = atHitTime - 2.0
        
        var startTime = atHitTime - 2.5
        
        let staticSamples = attBuffer.filter {
            $0.t >= searchStartWindow && $0.t <= searchEndWindow && $0.gyroMag <= 0.1
        }
        
        if let lastStatic = staticSamples.last {
            startTime = lastStatic.t
        }
        
        var peakTime = startTime
        var maxAccel: Double = 0.0
        var prevSample: AttSample? = nil
        
        for sample in attBuffer {
            if sample.t < startTime { continue }
            if sample.t > atHitTime { break }
            
            if let prev = prevSample {
                let dt = sample.t - prev.t
                if dt > 0 {
                    let accel = (sample.gyroMag - prev.gyroMag) / dt
                    if accel > maxAccel {
                        maxAccel = accel
                        peakTime = sample.t
                    }
                }
            }
            prevSample = sample
        }
        
        let totalDuration = endTime - startTime
        let peakDuration = peakTime - startTime
        
        var r: Double = 0.0
        if totalDuration > 0 {
            r = peakDuration / totalDuration
        }
        
        print("🚀 --- Swing Analysis (Normalized 0-1) ---")
        print(String(format: "⏱ Duration: %.2fs (Start to Impact)", totalDuration))
        print(String(format: "⚡ Peak Accel: %.1f rad/s²", maxAccel))
        print(String(format: "📍 Peak Position (r): %.3f", r))
        
        DispatchQueue.main.async { [weak self] in
            self?.lastPeakPositionR = r
        }
        
        // ★ iOSへ送信するためにrを保存
        self.currentPeakPositionR = r
    }
    
    // MARK: - Send Analysis to iOS
    private func sendAnalysisToiOS() {
        guard let impactTime = currentImpactTimestamp else {
            print("⚠️ No impact detected, skipping analysis send")
            return
        }
        
        let duration = startTime.map { -$0.timeIntervalSinceNow } ?? 0
        
        let analysis = ServeAnalysis(
            maxAcceleration: 0.0,  // ダミー値（必要に応じて実装）
            maxAngularVelocity: 0.0,  // ダミー値
            estimatedSwingSpeed: 0.0,  // ダミー値
            duration: duration,
            recordedAt: Date(),
            impactTimestamp: impactTime,
            impactRacketYaw: Double(lastFaceYawDeg),
            impactRacketPitch: Double(lastFacePitchDeg),
            swingPeakPositionR: currentPeakPositionR
        )
        
        watchManager.sendAnalysisResult(analysis)
        
        print("📤 Sent analysis to iOS:")
        print("   Impact timestamp: \(String(format: "%.6f", impactTime))s")
        print("   Racket yaw: \(String(format: "%.1f", lastFaceYawDeg))°")
        print("   Racket pitch: \(String(format: "%.1f", lastFacePitchDeg))°")
        print("   Peak position (r): \(String(format: "%.3f", currentPeakPositionR))")
    }

    private func stopIMU() {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
        attBuffer.removeAll()
        effectiveSampleRate = 0.0
    }

    // MARK: - Calibration Flow
    func beginCalibLevel() {
        calibStage = .levelPrompt
        ensureIMUStarted()
        WKInterfaceDevice.current().play(.start)
        statusDetail = "ラケット(Watch面を上)を地面に置いてください →『水平登録』"
    }

    func commitCalibLevel() {
        guard let last = attBuffer.last else {
            WKInterfaceDevice.current().play(.failure)
            return
        }
        R_calib = last.R
        hasLevelCalib = true
        calibStage = .levelDone
        WKInterfaceDevice.current().play(.success)
        statusDetail = "水平キャリブ: 登録完了"
    }

    func beginCalibDirection() {
        guard hasLevelCalib, R_calib != nil else {
            WKInterfaceDevice.current().play(.failure)
            statusDetail = "先に水平キャリブを実施してください"
            return
        }
        calibStage = .dirPrompt
        WKInterfaceDevice.current().play(.start)
        statusDetail = "ラケットを立てて狙う方向へ面を向け →『方向登録』"
    }

    func commitCalibDirection() {
        guard let R_calib = R_calib else { return }
        guard let last = attBuffer.last else {
            WKInterfaceDevice.current().play(.failure)
            return
        }

        let R_world_dir = simd_mul(simd_inverse(R_calib), last.R)
        let y_world = simd_normalize(simd_mul(R_world_dir, simd_float3(0, 1, 0)))
        let n0_world = simd_normalize(simd_mul(R_world_dir, n_device))

        yAxisWorld_calib = y_world
        faceNormal0World = n0_world

        hasDirCalib = true
        calibStage = .dirDone
        WKInterfaceDevice.current().play(.success)
        statusDetail = "方向キャリブ: 登録完了"
    }

    func finishCalibration() {
        guard hasLevelCalib, hasDirCalib else {
            WKInterfaceDevice.current().play(.failure)
            statusDetail = "キャリブ未完了です"
            return
        }
        calibStage = .ready
        WKInterfaceDevice.current().play(.success)
        statusDetail = "キャリブ終了：準備完了"
    }

    // MARK: - Face Angle Logic
    private func calculateFaceAngles(from R: simd_float3x3) -> (roll: Float, pitch: Float)? {
        guard
            let R_calib = R_calib,
            let yAxis = yAxisWorld_calib,
            let n0 = faceNormal0World
        else { return nil }

        let R_world = simd_mul(simd_inverse(R_calib), R)
        let n_world = simd_normalize(simd_mul(R_world, n_device))

        let pitch = atan2f(n_world.z, hypotf(n_world.x, n_world.y)) * 180.0 / .pi

        let u = simd_normalize(yAxis)
        func projectPerp(_ v: simd_float3, axis: simd_float3) -> simd_float3 {
            let v_perp = v - simd_dot(v, axis) * axis
            let len = simd_length(v_perp)
            return (len > 1e-6) ? v_perp / len : simd_float3(0,0,0)
        }
        
        let a = projectPerp(n0, axis: u)
        let b = projectPerp(n_world, axis: u)
        
        if simd_length(a) < 1e-6 || simd_length(b) < 1e-6 { return nil }

        let cross_ab = simd_cross(a, b)
        let sinTerm = simd_dot(u, cross_ab)
        let cosTerm = simd_dot(a, b)
        let rollRad = atan2f(sinTerm, cosTerm)
        
        return (rollRad * 180.0 / .pi, pitch)
    }

    // MARK: - Helpers
    private func attitudeToR(_ att: CMAttitude) -> simd_float3x3 {
        let m = att.rotationMatrix
        return simd_float3x3(
            SIMD3(Float(m.m11), Float(m.m12), Float(m.m13)),
            SIMD3(Float(m.m21), Float(m.m22), Float(m.m23)),
            SIMD3(Float(m.m31), Float(m.m32), Float(m.m33))
        )
    }

    func resetAll() {
        if isRecording { stopRecording() }
        stopIMU()
        R_calib = nil
        yAxisWorld_calib = nil
        faceNormal0World = nil
        hasLevelCalib = false
        hasDirCalib = false
        calibStage = .idle
        lastFaceYawDeg = 0
        lastFacePitchDeg = 0
        lastFaceAdvice = ""
        lastPeakPositionR = 0.0
        lastPeakEvalText = ""
        currentImpactTimestamp = nil
        currentPeakPositionR = 0.0
        statusHeader = "⏸ Idle"
        statusDetail = "リセット完了"
        collectionState = .idle
    }
}

// MARK: - HKWorkoutSessionDelegate
extension ServeAnalyzer: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                       didChangeTo toState: HKWorkoutSessionState,
                       from fromState: HKWorkoutSessionState,
                       date: Date) {
        DispatchQueue.main.async {
            switch toState {
            case .running:
                print("🏋️ Workout session state: Running")
            case .ended:
                print("🏁 Workout session state: Ended")
            case .paused:
                print("⏸️ Workout session state: Paused")
            case .prepared:
                print("🔧 Workout session state: Prepared")
            case .stopped:
                print("🛑 Workout session state: Stopped")
            @unknown default:
                print("❓ Workout session state: Unknown")
            }
        }
    }
    
    func workoutSession(_ workoutSession: HKWorkoutSession,
                       didFailWithError error: Error) {
        print("❌ Workout session failed: \(error.localizedDescription)")
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate
extension ServeAnalyzer: HKLiveWorkoutBuilderDelegate {
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                       didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // データ収集時の処理（必要に応じて実装）
    }
    
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // イベント収集時の処理（必要に応じて実装）
    }
}
