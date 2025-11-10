// ーーーーー Audio + IMU + Calibration + Face Angle + 指示UI（Roll対応） ーーーーー
//
//  ServeAnalyzer.swift
//  TennisServeAnalyzer Watch App
//
//  🎙️ Audioでインパクト検出（RMS/Peak/ZCR）
//  🎯 ヒット瞬間のIMU姿勢からラケット面角（Roll=Y軸回り / Pitch）を算出
//  🧭 二段キャリブ（水平→方向）をUI指示に沿って実施
//

import Foundation
import CoreMotion
import Combine
import AVFoundation
import simd
import WatchKit

final class ServeAnalyzer: ObservableObject {
    // MARK: - Public (UI Bindings)
    @Published var collectionState: DataCollectionState = .idle
    @Published var isRecording: Bool = false
    @Published var currentSampleCount: Int = 0                      // 互換用（未使用）
    @Published var effectiveSampleRate: Double = 0.0                // IMU実稼働Hz

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
    // ※互換のためプロパティ名は yaw を残していますが、中身は「Roll（Y軸回り）」です
    @Published var lastFaceYawDeg: Float = 0.0     // = Roll (signed)
    @Published var lastFacePitchDeg: Float = 0.0   // Pitch
    @Published var lastFaceAdvice: String = ""

    // オーディオ・メトリクス（UI表示用）
    @Published var lastAudioRmsDb: Float = -160.0
    @Published var lastAudioPeakDb: Float = -160.0

    // MARK: - Internals
    private let watchManager = WatchConnectivityManager.shared

    // IMU
    private let motionManager = CMMotionManager()
    private let imuHz: Double = 100.0

    // キャリブ
    private var R_calib: simd_float3x3? = nil            // 水平基準（床置き）
    // 方向キャリブ（Rollの基準に必要な2要素）
    private var yAxisWorld_calib: simd_float3? = nil     // 世界座標における「端末Y軸」（ディスプレイ上方向）
    private var faceNormal0World: simd_float3? = nil     // 方向キャリブ時の面法線（世界座標）

    // 軸仮定（必要なら±入替）
    // Watch画面がボール側＝画面外向き(+Z)を面法線と仮定（装着が逆なら ± を切替）
    private let n_device = simd_float3(0, 0, 1)

    // 姿勢バッファ（ヒット時刻に最近傍を引き当て）
    private struct AttSample { let t: TimeInterval; let R: simd_float3x3 }
    private var attBuffer: [AttSample] = []
    private let attBufferMax = 240

    // Audio
    private let audioEngine = AVAudioEngine()
    private var audioTapInstalled = false

    // Audio hit detection
    private let audioWinSize = 512
    private var lastHitMs: Int64 = 0
    private let hitDebounceMs: Int64 = 200
    private var warmupWindows: Int = 5

    private var emaPeakDb: Float? = nil
    private let emaAlpha: Float = 0.20
    private let relJumpDbThresh: Float = 10.0
    private let zcrMinForHit: Float = 0.03

    private var lastAudioTms: Int64 = 0

    // その他（互換）
    private var startTime: Date?
    private var lastSentBatchTime: Date?
    private var totalBatchesSent: Int = 0

    // MARK: - Init
    init() {
        print("⌚ ServeAnalyzer init (Audio + IMU + Calibration, Roll)")
        connectionStatusText = (watchManager.session?.isReachable ?? false) ? "iPhone接続" : "未接続"
        startStatusTimer()
    }

    // MARK: - Status / Timers
    private func startStatusTimer() {
        // 2秒毎にUIの軽い更新
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tickStatus()
        }
    }

    private func tickStatus() {
        connectionStatusText = (watchManager.session?.isReachable ?? false) ? "iPhone接続" : "未接続"

        let rec = isRecording ? "📊 Recording" : "⏸ Idle"
        var detail = String(format: "Audio RMS %.1f / Peak %.1f dBFS", lastAudioRmsDb, lastAudioPeakDb)

        switch calibStage {
        case .idle:
            detail += " / キャリブ未開始"
        case .levelPrompt:
            detail += " / 『水平』置きで登録待ち"
        case .levelDone:
            detail += " / 水平OK"
        case .dirPrompt:
            detail += " / 『方向』立て置きで登録待ち"
        case .dirDone:
            detail += " / 方向OK"
        case .ready:
            detail += " / キャリブ完了：準備完了"
        }

        statusHeader = rec
        statusDetail = detail

        if motionManager.isDeviceMotionActive {
            samplingStatus = String(format: "IMU 稼働中: %.0f Hz", effectiveSampleRate)
        } else {
            samplingStatus = String(format: "IMU %.0fHz 設定済み", imuHz)
        }

        print(String(format:"🎙️ Audio status → RMS %.1f dBFS, Peak %.1f dBFS", lastAudioRmsDb, lastAudioPeakDb))
    }

    // MARK: - Recording Control
    func startRecording() {
        guard !isRecording else { return }
        print("🎬 Starting recording...")

        startTime = Date()
        lastHitMs = 0
        warmupWindows = 5
        emaPeakDb = nil
        lastAudioTms = 0
        lastAudioRmsDb = -160
        lastAudioPeakDb = -160
        lastFaceYawDeg = 0   // ← roll
        lastFacePitchDeg = 0
        lastFaceAdvice = ""

        // Audio start
        startAudioCapture()

        isRecording = true
        collectionState = DataCollectionState.collecting
        statusHeader = "📊 Recording"
        print("✅ Recording started")
    }

    func stopRecording() {
        guard isRecording else { return }
        print("⏹ Stopping recording...")

        stopAudioCapture()

        isRecording = false
        collectionState = DataCollectionState.completed

        let duration = startTime.map { -$0.timeIntervalSinceNow } ?? 0
        print("✅ Recording stopped (elapsed: \(String(format: "%.1f", duration))s)")
        statusHeader = "⏹ Stopped"
    }

    // MARK: - IMU Lifecyle
    private func ensureIMUStarted() {
        guard motionManager.isDeviceMotionAvailable else {
            print("❌ Device Motion not available")
            statusDetail = "❌ Motion NOT available"
            return
        }
        if !motionManager.isDeviceMotionActive {
            motionManager.deviceMotionUpdateInterval = 1.0 / imuHz
            motionManager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] dm, _ in
                guard let self = self, let dm = dm else { return }
                let R = self.attitudeToR(dm.attitude)
                let t = dm.timestamp // seconds since boot
                self.attBuffer.append(.init(t: t, R: R))
                if self.attBuffer.count > self.attBufferMax {
                    self.attBuffer.removeFirst(self.attBuffer.count - self.attBufferMax)
                }
            }
            effectiveSampleRate = imuHz
            print("✅ IMU started @ \(imuHz) Hz")
        }
    }

    private func stopIMU() {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
            print("🛑 IMU stopped")
        }
        attBuffer.removeAll()
        effectiveSampleRate = 0.0
    }

    // MARK: - Calibration Flow
    /// ② “水平キャリブレーション” → IMU自動起動 → 平面置きで登録
    func beginCalibLevel() {
        calibStage = .levelPrompt
        ensureIMUStarted() // ← 自動起動
        WKInterfaceDevice.current().play(.start)
        statusDetail = "ラケット(Watch面を上)を地面に置いてください →『水平登録』"
    }

    func commitCalibLevel() {
        guard let last = attBuffer.last else {
            print("⚠️ calibLevel: no attitude sample yet")
            WKInterfaceDevice.current().play(.failure)
            return
        }
        R_calib = last.R
        hasLevelCalib = true
        calibStage = .levelDone
        WKInterfaceDevice.current().play(.success)
        statusDetail = "水平キャリブ: 登録完了"
        print("🔧 calib: level captured")
    }

    /// ④ “方向キャリブレーション”
    /// ディスプレイ正面を打ちたい方向へ、ディスプレイ上端が+Yになるように立てる。
    /// → 世界座標の「端末Y軸」と「面法線（基準）」を保存。
    func beginCalibDirection() {
        guard hasLevelCalib, R_calib != nil else {
            WKInterfaceDevice.current().play(.failure)
            statusDetail = "先に水平キャリブを実施してください"
            print("⚠️ calibDirection: level calib not yet set")
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
            print("⚠️ calibDirection: no attitude sample yet")
            return
        }

        let R_world_dir = simd_mul(simd_inverse(R_calib), last.R)

        // 世界座標における「端末Y軸（ディスプレイ上方向）」
        let y_world = simd_normalize(simd_mul(R_world_dir, simd_float3(0, 1, 0)))
        // 方向キャリブ時の面法線（世界座標）
        let n0_world = simd_normalize(simd_mul(R_world_dir, n_device))

        // 妥当性チェック（Y軸と面法線が直交に近いことを軽く確認）
        let dotYN = abs(simd_dot(y_world, n0_world))
        if dotYN > 0.5 {
            // 面法線とY軸がほぼ同方向＝装着向きの想定と違う可能性
            print("⚠️ calibDirection: face normal not orthogonal to Y (|dot|=\(dotYN)). Check axes.")
        }

        yAxisWorld_calib = y_world
        faceNormal0World = n0_world

        hasDirCalib = true
        calibStage = .dirDone
        WKInterfaceDevice.current().play(.success)
        statusDetail = "方向キャリブ: 登録完了"
        print("🔧 calib: saved yAxisWorld & faceNormal0World")
    }

    /// ⑦ “キャリブレーション終了　準備完了”
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

    // MARK: - Audio
    private func startAudioCapture() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: [])
        } catch {
            print("❌ AVAudioSession error: \(error)")
            return
        }

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let self = self else { return }
            if !granted {
                print("❌ Microphone permission not granted")
                return
            }
            DispatchQueue.main.async {
                self.installAudioTapIfNeeded()
                do {
                    try self.audioEngine.start()
                    print("🎙️ Audio engine started")
                } catch {
                    print("❌ Audio engine start failed: \(error)")
                }
            }
        }
    }

    private func installAudioTapIfNeeded() {
        guard !audioTapInstalled else { return }
        let input = audioEngine.inputNode
        let format = input.inputFormat(forBus: 0)
        let bufferSize: AVAudioFrameCount = 512

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer: buffer, format: format)
        }
        audioTapInstalled = true
        print("🎙️ Audio tap installed (sr: \(format.sampleRate), ch: \(format.channelCount), buf: \(bufferSize))")
    }

    private func stopAudioCapture() {
        if audioTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioTapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [])
        } catch {
            print("⚠️ AVAudioSession deactivate error: \(error)")
        }
        print("🛑 Audio engine stopped")
    }

    // === ヒット検出：EMAベースライン比較＋デバウンス ===
    private func processAudioBuffer(buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        guard let chData = buffer.floatChannelData else { return }
        let ch0 = chData[0]
        let frameCount = Int(buffer.frameLength)
        if frameCount == 0 { return }

        let t0ms = Int64(ProcessInfo.processInfo.systemUptime * 1000.0)
        let sr = Float(format.sampleRate)
        let win = audioWinSize

        var idx = 0
        var lastRmsDbThisCall: Float = -160.0
        var lastPeakDbThisCall: Float = -160.0

        while idx + win <= frameCount {
            var sum: Float = 0
            var peak: Float = 0
            var zeroCross = 0
            var prev = ch0[idx]
            for i in 0..<win {
                let x = ch0[idx + i]
                sum += x * x
                let a = fabsf(x); if a > peak { peak = a }
                if (prev >= 0 && x < 0) || (prev < 0 && x >= 0) { zeroCross += 1 }
                prev = x
            }
            let rms = sqrtf(sum / Float(win))
            let minDb: Float = -160.0
            let rmsDb  = max(20.0 * log10f(max(rms,  1e-8)), minDb)
            let peakDb = max(20.0 * log10f(max(peak, 1e-8)), minDb)
            let zcr    = Float(zeroCross) / Float(win)

            let centerOffsetMs = Int64( (Double(idx) + Double(win)/2.0) / Double(sr) * 1000.0 )
            let centerMs = t0ms + centerOffsetMs

            let baseline = emaPeakDb ?? peakDb
            let relFromBaseline = peakDb - baseline

            if emaPeakDb == nil {
                emaPeakDb = peakDb
            } else {
                emaPeakDb = emaAlpha * peakDb + (1 - emaAlpha) * (emaPeakDb ?? peakDb)
            }

            let absOk = (peakDb >= -15.0) || (rmsDb >= -25.0 && peakDb >= -20.0)
            let relOk = (relFromBaseline >= relJumpDbThresh)
            // （必要なら）ZCRゲートを戻す: let zcrOk = (zcr >= zcrMinForHit)
            let debounceOK = (centerMs - lastHitMs) >= hitDebounceMs
            let warmupDone = (warmupWindows <= 0)
            let isHit = warmupDone && absOk && relOk && debounceOK

            let mark = isHit ? "🎯" : " "
            print(String(
                format: "%@AUD t=%lldms win=%d | RMS=%.1f dBFS, Peak=%.1f dBFS, ΔPeak(baseline)=%.1f dB, ZCR=%.3f",
                mark, centerMs, win, rmsDb, peakDb, relFromBaseline, zcr
            ))

            if isHit {
                lastHitMs = centerMs
                if let (rollDeg, pitchDeg) = snapshotFaceAngles(atMs: centerMs) {
                    let advice = advise(rollDeg: rollDeg, pitchDeg: pitchDeg)
                    DispatchQueue.main.async { [weak self] in
                        self?.lastFaceYawDeg = rollDeg     // ← roll を保存
                        self?.lastFacePitchDeg = pitchDeg
                        self?.lastFaceAdvice = advice
                    }
                    print(String(format: "🎯 FACE roll=%.1f°, pitch=%.1f°  %@", rollDeg, pitchDeg, advice))
                } else {
                    print("⚠️ FACE snapshot unavailable (no calib or no IMU sample)")
                }
            }

            if warmupWindows > 0 { warmupWindows -= 1 }
            lastRmsDbThisCall  = rmsDb
            lastPeakDbThisCall = peakDb

            idx += win
        }

        DispatchQueue.main.async { [weak self] in
            self?.lastAudioRmsDb  = lastRmsDbThisCall
            self?.lastAudioPeakDb = lastPeakDbThisCall
        }

        lastAudioTms = t0ms
    }

    // MARK: - Face angles snapshot（Roll=Y軸回り / Pitch）
    private func snapshotFaceAngles(atMs: Int64) -> (Float, Float)? {
        guard
            let R_calib = R_calib,
            let yAxis = yAxisWorld_calib,
            let n0 = faceNormal0World
        else { return nil }

        let t_audio = Double(atMs) / 1000.0
        guard let near = attBuffer.min(by: { abs($0.t - t_audio) < abs($1.t - t_audio) }) else { return nil }

        // 現在の世界座標姿勢
        let R_world = simd_mul(simd_inverse(R_calib), near.R)
        let n_world = simd_normalize(simd_mul(R_world, n_device))

        // ---- Pitch（下向きをマイナス）----
        let pitch = atan2f(n_world.z, hypotf(n_world.x, n_world.y)) * 180.0 / .pi

        // ---- Roll（Y軸= yAxis まわりで n0 → n_world への回転角）----
        let u = simd_normalize(yAxis)

        // u に直交な平面へ射影して正規化
        func projectPerp(_ v: simd_float3, axis: simd_float3) -> simd_float3 {
            let v_perp = v - simd_dot(v, axis) * axis
            let len = simd_length(v_perp)
            return (len > 1e-6) ? v_perp / len : simd_float3(0,0,0)
        }
        let a = projectPerp(n0, axis: u)
        let b = projectPerp(n_world, axis: u)
        if simd_length(a) < 1e-6 || simd_length(b) < 1e-6 { return nil }

        // 符号付き角：atan2( u·(a×b), a·b )
        let cross_ab = simd_cross(a, b)
        let sinTerm = simd_dot(u, cross_ab)
        let cosTerm = simd_dot(a, b)
        let rollRad = atan2f(sinTerm, cosTerm)
        let rollDeg = rollRad * 180.0 / .pi

        return (rollDeg, pitch)
    }

    // MARK: - Threshold advice（Roll±5° / Pitch -10°±10°）
    private func advise(rollDeg: Float, pitchDeg: Float) -> String {
        var msgs: [String] = []

        // 左右（Roll）
        if abs(rollDeg) > 5 {
            msgs.append("ボールを打つ時はラケット面を真っ直ぐ打ちたい方向に向けましょう。")
        }

        // 上下（Pitch）
        if pitchDeg < -70 || pitchDeg < -20 {
            msgs.append("ラケット面が下を向いています。ボールがネットにかかりやすいです。")
        } else if pitchDeg > 50 || pitchDeg > 0 {
            msgs.append("ラケット面が上を向いています。ボールが浮いてしまいます。")
        }
        return msgs.joined(separator: " / ")
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

    // 公開ユーティリティ（テスト・デモ用）
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

