// ーーーーー IMU Only Impact Detection + Efficiency Analysis ーーーーー
//
//  ServeAnalyzer.swift
//  TennisServeAnalyzer Watch App
//
//  🚀 Audio機能を全削除し、IMUの衝撃検知のみで実装
//  📊 スイング効率分析（加速ピークタイミング診断）を追加
//  🎯 スイング速度(Gyro)と衝撃(Accel Jerk)を監視してインパクトを特定
//

import Foundation
import CoreMotion
import Combine
import simd
import WatchKit

final class ServeAnalyzer: ObservableObject {
    // MARK: - Public (UI Bindings)
    @Published var collectionState: DataCollectionState = .idle
    @Published var isRecording: Bool = false
    @Published var currentSampleCount: Int = 0
    @Published var effectiveSampleRate: Double = 0.0

    // ステータス表示
    @Published var statusHeader: String = "⏸ Idle"
    @Published var statusDetail: String = "起動しました"
    @Published var samplingStatus: String = "IMU 100Hz 設定済み"
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
    private let attBufferMax = 200 // 2秒分保持

    // 時間変換用
    private var timebaseInfo = mach_timebase_info_data_t()
    private var startTime: Date?

    // MARK: - Impact Detection Logic (IMU Based)
    
    // デバウンス
    private let hitDebounceTime: TimeInterval = 1.0
    private var lastHitTime: TimeInterval = 0
    
    // 閾値設定
    private let swingGateThreshold: Double = 5.0  // rad/s
    private let impactShockThreshold: Double = 4.0 // G
    
    // 前回の加速度（変化量計算用）
    private var lastUserAccelMag: Double = 0.0

    // MARK: - Init
    init() {
        print("⌚ ServeAnalyzer init (IMU Impact + Efficiency Analysis)")
        connectionStatusText = (watchManager.session?.isReachable ?? false) ? "iPhone接続" : "未接続"
        startStatusTimer()
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

        startTime = Date()
        lastHitTime = 0
        lastUserAccelMag = 0
        lastFaceYawDeg = 0
        lastFacePitchDeg = 0
        lastFaceAdvice = ""

        isRecording = true
        collectionState = DataCollectionState.collecting
        statusHeader = "📊 Recording"
        print("✅ Recording started (IMU Only)")
    }

    func stopRecording() {
        guard isRecording else { return }
        print("⏹ Stopping recording...")

        isRecording = false
        collectionState = DataCollectionState.completed

        let duration = startTime.map { -$0.timeIntervalSinceNow } ?? 0
        print("✅ Recording stopped (elapsed: \(String(format: "%.1f", duration))s)")
        statusHeader = "⏹ Stopped"
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
        // 1. データ抽出
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
        
        // バッファに追加
        attBuffer.append(.init(t: t, R: R, gyroMag: gyroMag, userAccelMag: userAccelMag))
        if attBuffer.count > attBufferMax {
            attBuffer.removeFirst(attBuffer.count - attBufferMax)
        }
        
        // 2. ヒット判定ロジック (Recording中のみ)
        if isRecording {
            detectImpactFromMotion(t: t, gyroMag: gyroMag, userAccelMag: userAccelMag)
            
            // リアルタイムログ出力（間引き）
            if t - lastLogTimestamp > 0.01 {
                lastLogTimestamp = t
                let tMs = Int64(t * 1000)
                if let angles = calculateFaceAngles(from: R) {
                    let deltaAccel = abs(userAccelMag - lastUserAccelMag)
                    print(String(format: "%lldms | Gyro:%.1f | Acc:%.1f | ΔAcc:%.1f | R:%.1f P:%.1f",
                                 tMs, gyroMag, userAccelMag, deltaAccel, angles.roll, angles.pitch))
                }
            }
        }
        
        lastUserAccelMag = userAccelMag
    }
    
    /// 衝撃検知によるヒット判定
    private func detectImpactFromMotion(t: TimeInterval, gyroMag: Double, userAccelMag: Double) {
        if t - lastHitTime < hitDebounceTime { return }
        if gyroMag < swingGateThreshold { return }
        
        let deltaAccel = abs(userAccelMag - lastUserAccelMag)
        
        if deltaAccel > impactShockThreshold {
            lastHitTime = t
            
            // ピークサーチでインパクト時刻を特定
            if let bestSample = findBestImpactSample(triggerTime: t),
               let angles = calculateFaceAngles(from: bestSample.R) {
                
                let advice = advise(rollDeg: angles.roll, pitchDeg: angles.pitch)
                
                DispatchQueue.main.async { [weak self] in
                    self?.lastFaceYawDeg = angles.roll
                    self?.lastFacePitchDeg = angles.pitch
                    self?.lastFaceAdvice = advice
                    WKInterfaceDevice.current().play(.success)
                }
                
                let triggerMs = Int64(t * 1000)
                let bestMs = Int64(bestSample.t * 1000)
                
                print("\n🔥🔥🔥 IMPACT DETECTED (IMU) 🔥🔥🔥")
                print(String(format: "🎯 HIT @ %lldms (Trig:%lld) | Gyro=%.1f | 左右=%.1f°, 上下=%.1f°",
                             bestMs, triggerMs, bestSample.gyroMag, angles.roll, angles.pitch))
                
                // ★ここでスイング効率分析を実行・表示
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
        
        // 最大加速の直後(約20ms後)をインパクトとする
        let targetTime = maxGyroSample.t + 0.02
        return attBuffer.min(by: { abs($0.t - targetTime) < abs($1.t - targetTime) })
    }

    // MARK: - ★ Swing Efficiency Analysis Logic (Added)
    
    /// スイング効率の分析：インパクト前のピーク加速タイミングを特定してログ出力
    private func analyzeSwingEfficiency(atHitTime: TimeInterval) {
        // 検索範囲: インパクト前 200ms 〜 0ms
        let searchWindow = 0.2 // 200ms
        
        var maxAccel: Double = 0
        var maxAccelTimeDiff: Double = 0
        var prevSample: AttSample? = nil
        
        // バッファを走査して、指定範囲内の最大角加速度を探す
        for sample in attBuffer {
            let diffSec = sample.t - atHitTime
            
            // インパクト前 (-200ms ~ -5ms) の範囲のみ対象
            if diffSec >= -searchWindow && diffSec < -0.005 {
                if let prev = prevSample {
                    let dt = sample.t - prev.t
                    if dt > 0 {
                        let dGyro = sample.gyroMag - prev.gyroMag
                        let accel = dGyro / dt // 角加速度 (rad/s^2)
                        
                        if accel > maxAccel {
                            maxAccel = accel
                            maxAccelTimeDiff = diffSec
                        }
                    }
                }
            }
            prevSample = sample
        }
        
        let diffMs = Int(maxAccelTimeDiff * 1000)
        
        print("🚀 --- Swing Efficiency Analysis ---")
        print(String(format: "⚡ Peak Acceleration: %.1f rad/s²", maxAccel))
        print(String(format: "⏱ Timing: %d ms before impact", abs(diffMs)))
        
        // 評価
        if diffMs > -30 {
            print("💎 Evaluation: EXCELLENT (インパクト直前の最大加速)")
        } else if diffMs > -80 {
            print("✅ Evaluation: GOOD (標準的な加速タイミング)")
        } else {
            print("⚠️ Evaluation: EARLY (加速が早い・手打ちの可能性)")
        }
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

    // MARK: - Threshold advice
    private func advise(rollDeg: Float, pitchDeg: Float) -> String {
        var msgs: [String] = []
        if abs(rollDeg) > 5 { msgs.append("面を真っ直ぐ向けましょう") }
        if pitchDeg < -70 || pitchDeg < -20 { msgs.append("面が下向き(ネット注意)") }
        else if pitchDeg > 50 || pitchDeg > 0 { msgs.append("面が上向き(アウト注意)") }
        return msgs.isEmpty ? "Good Shot!" : msgs.joined(separator: "/")
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
        lastFaceYawDeg = 0; lastFacePitchDeg = 0; lastFaceAdvice = ""
        statusHeader = "⏸ Idle"
        statusDetail = "リセット完了"
        collectionState = .idle
    }
}
