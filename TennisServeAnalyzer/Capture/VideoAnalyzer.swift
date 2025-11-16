//
//  VideoAnalyzer.swift
//  TennisServeAnalyzer
//
//  Video analysis with Pose Detection + IMU Integration
//  🔧 修正: 既存APIに対応したメソッド呼び出し
//

import Foundation
import AVFoundation
import CoreMedia
import Combine

// MARK: - Analysis State
enum AnalysisState {
    case idle              // アプリ起動直後
    case setupCamera       // カメラセッティング中（オーバーレイ表示）
    case recording         // 撮影中
    case analyzing         // 解析中
    case completed(ServeMetrics)  // 解析完了
    case error(String)     // エラー
}

// MARK: - Video Analyzer (ObservableObject for SwiftUI)
class VideoAnalyzer: NSObject, ObservableObject {
    // MARK: Published Properties
    @Published var state: AnalysisState = .idle
    @Published var currentFPS: Double = 0.0
    @Published var detectedPose: PoseData? = nil
    @Published var detectedBall: BallDetection? = nil
    @Published var trophyPoseDetected: Bool = false
    @Published var trophyAngles: TrophyPoseAngles? = nil
    @Published var pelvisPosition: CGPoint? = nil
    
    // 🔧 追加: タイマー管理
    private var autoStopTimer: DispatchWorkItem?
    private var impactStopTimer: DispatchWorkItem?
    
    // Watch connectivity
    private var watchManager: WatchConnectivityManager?
    @Published var isWatchConnected: Bool = false
    @Published var watchSamplesReceived: Int = 0
    
    // Components
    private var videoCaptureManager: VideoCaptureManager?
    private var poseDetector: PoseDetector?
    private var eventDetector: EventDetector?
    private var ballTracker: BallTracker?
    
    // Session data
    private var frameCount: Int = 0
    private var poseHistory: [PoseData] = []
    private var trophyPoseEvent: TrophyPoseEvent?
    private var sessionStartTime: Date?
    
    // 時系列データ保存
    private struct FrameData {
        let timestamp: Double
        let angles: TrophyPoseAngles
        let ballPosition: CGPoint?
        let pelvisPosition: CGPoint?
    }
    private var frameDataHistory: [FrameData] = []
    
    // Watch IMU
    private var watchIMUHistory: [ServeSample] = []
    private var impactEvent: ImpactEvent?
    
    // Configuration
    private let maxSessionDuration: TimeInterval = 15.0
    private let poseDetectionInterval: Int = 2
    
    // MARK: - Initialization
    override init() {
        super.init()
        
        // Setup Watch connectivity
        setupWatchConnectivity()
        
        // 🔧 修正: 初期化時にカメラ権限をリクエスト（プレビューは表示しない）
        requestCameraPermission()
    }
    
    // MARK: - Camera Permission
    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    print("✅ Camera permission granted")
                } else {
                    print("❌ Camera permission denied")
                    self?.state = .error("カメラ権限が必要です")
                }
            }
        }
    }
    
    // MARK: - Watch Connectivity Setup
    private func setupWatchConnectivity() {
        watchManager = WatchConnectivityManager.shared
        
        // Monitor connection status
        watchManager?.$isWatchConnected
            .receive(on: DispatchQueue.main)
            .assign(to: &$isWatchConnected)
        
        watchManager?.$receivedSamplesCount
            .receive(on: DispatchQueue.main)
            .assign(to: &$watchSamplesReceived)
        
        // Setup callbacks
        watchManager?.onIMUDataReceived = { [weak self] sample in
            self?.handleWatchIMUSample(sample)
        }
        
        watchManager?.onBatchDataReceived = { [weak self] samples in
            self?.handleWatchBatchData(samples)
        }
    }
    
    // MARK: - 🎯 NEW: Camera Setup Flow
    /// カメラセッティング画面に遷移（オーバーレイ表示）
    func setupCamera() {
        guard case .idle = state else { return }
        
        print("📷 Setting up camera with baseline overlay...")
        prepareCameraPreview()
        state = .setupCamera
    }
    
    // MARK: - Camera Preview Preparation
    func prepareCameraPreview() {
        print("📷 Preparing camera preview...")
        
        // 既存のマネージャーをクリーンアップ
        videoCaptureManager?.stopRecording()
        videoCaptureManager = nil
        
        // 新しいVideoCaptureManagerを作成
        let manager = VideoCaptureManager()
        manager.delegate = self
        videoCaptureManager = manager
        
        // プレビューレイヤーを準備
        _ = self.getPreviewLayer()
        
        // 🔧 追加: プレビューセッションを開始（録画なし）
        manager.startPreview()
        
        print("✅ Camera preview ready")
    }
    
    // MARK: - Watch Data Handlers
    private func handleWatchIMUSample(_ sample: ServeSample) {
        self.addIMUSample(sample)
    }
    
    private func handleWatchBatchData(_ samples: [ServeSample]) {
        for sample in samples {
            self.addIMUSample(sample)
        }
        detectImpactFromIMU()
    }
    
    // MARK: - Lazy Initialization
    private func getOrCreatePoseDetector() -> PoseDetector? {
        if poseDetector == nil {
            poseDetector = PoseDetector()
        }
        return poseDetector
    }
    
    private func getOrCreateEventDetector() -> EventDetector? {
        if eventDetector == nil {
            eventDetector = EventDetector()
        }
        return eventDetector
    }
    
    private func getOrCreateBallTracker() -> BallTracker? {
        if ballTracker == nil {
            ballTracker = BallTracker()
        }
        return ballTracker
    }
    
    // MARK: - Main Flow
    func startRecording() {
        // 🔧 修正: setupCamera状態からのみ録画開始可能
        guard case .setupCamera = state else {
            print("⚠️ Cannot start recording from state: \(state)")
            return
        }
        
        print("🎬 Starting recording from camera setup...")
        startRecordingInternal()
    }
    
    private func startRecordingInternal() {
        // 🔧 修正: 既存のマネージャーをクリーンアップ
        videoCaptureManager?.stopRecording()
        videoCaptureManager = nil
        
        // Initialize video capture
        let manager = VideoCaptureManager()
        manager.delegate = self
        videoCaptureManager = manager
        
        // 🔧 修正: 既存のタイマーをキャンセル
        autoStopTimer?.cancel()
        autoStopTimer = nil
        impactStopTimer?.cancel()
        impactStopTimer = nil
        
        // Reset data
        frameCount = 0
        poseHistory.removeAll()
        watchIMUHistory.removeAll()
        trophyPoseEvent = nil
        impactEvent = nil
        sessionStartTime = Date()
        trophyPoseDetected = false
        trophyAngles = nil
        pelvisPosition = nil
        frameDataHistory.removeAll()
        
        // Start Watch recording
        watchManager?.startWatchRecording()
        
        // Start recording
        state = .recording
        videoCaptureManager?.startRecording()
        
        print("=== 測定開始 ===")
        
        // 🔧 修正: タイマーを保持して管理
        let timerWorkItem = DispatchWorkItem { [weak self] in
            print("⏰ 自動停止タイマー発火")
            self?.stopRecording()
        }
        autoStopTimer = timerWorkItem
        
        DispatchQueue.main.asyncAfter(deadline: .now() + maxSessionDuration, execute: timerWorkItem)
    }
    
    func stopRecording() {
        guard case .recording = state else { return }
        
        // 🔧 修正: タイマーをキャンセル
        autoStopTimer?.cancel()
        autoStopTimer = nil
        impactStopTimer?.cancel()
        impactStopTimer = nil
        
        watchManager?.stopWatchRecording()
        videoCaptureManager?.stopRecording()
        
        state = .analyzing
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.finalizeAnalysis()
        }
    }
    
    // MARK: - Frame Processing
    private func processFrame(sampleBuffer: CMSampleBuffer, timestamp: Double) {
        frameCount += 1
        
        // Pose detection (every N frames)
        if frameCount % poseDetectionInterval == 0, let poseDet = getOrCreatePoseDetector() {
            if let pose = poseDet.detectPose(from: sampleBuffer, timestamp: timestamp) {
                poseHistory.append(pose)
                
                DispatchQueue.main.async { [weak self] in
                    self?.detectedPose = pose
                }
            }
        }
        
        // Ball detection (every frame)
        if let tracker = getOrCreateBallTracker() {
            if let ball = tracker.trackBall(from: sampleBuffer, timestamp: timestamp) {
                DispatchQueue.main.async { [weak self] in
                    self?.detectedBall = ball
                }
            }
            
            // Trophy pose detection
            detectTrophyPose(timestamp: timestamp)
        }
    }
    
    // MARK: - Trophy Pose Detection
    private func detectTrophyPose(timestamp: Double) {
        guard poseHistory.count >= 5 else { return }
        guard trophyPoseEvent == nil else { return }
        
        let recentPoses = Array(poseHistory.suffix(10))
        
        // 🔧 修正: トス頂点を取得（引数なし）
        let tossApex: BallApex? = ballTracker?.detectTossApex()
        
        for pose in recentPoses {
            // 🔧 修正: armpitAngle メソッドを使用
            guard let rightElbow = PoseDetector.calculateElbowAngle(from: pose, isRight: true),
                  let rightArmpit = PoseDetector.armpitAngle(pose, side: .right) else {
                continue
            }
            
            let elbowValid = (150...180).contains(rightElbow)
            let armpitValid = (70...110).contains(rightArmpit)
            
            if elbowValid && armpitValid {
                // 🔧 修正: leftHandAngles メソッドを使用
                let leftAngles = PoseDetector.leftHandAngles(pose)
                let leftShoulder = leftAngles?.torso
                let leftElbow = leftAngles?.extension
                
                // 🔧 修正: TrophyPoseEvent の正しい初期化
                trophyPoseEvent = TrophyPoseEvent(
                    timestamp: timestamp,
                    pose: pose,
                    tossApex: tossApex.map { (time: $0.timestamp, height: $0.height) },
                    confidence: pose.averageConfidence,
                    elbowAngle: rightElbow,
                    shoulderAbduction: nil,  // EventDetectorで計算される
                    isValid: true,
                    rightElbowAngle: rightElbow,
                    rightArmpitAngle: rightArmpit,
                    leftShoulderAngle: leftShoulder,
                    leftElbowAngle: leftElbow
                )
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.trophyPoseDetected = true
                    self.trophyAngles = TrophyPoseAngles(
                        rightElbow: rightElbow,
                        rightArmpit: rightArmpit
                    )
                    // 🔧 修正: 骨盤位置を手動計算
                    self.pelvisPosition = self.calculateHipCenter(from: pose)
                }
                
                print("🏆 Trophy pose detected!")
                print("   - Elbow: \(String(format: "%.1f", rightElbow))°")
                print("   - Armpit: \(String(format: "%.1f", rightArmpit))°")
                
                // 🔧 修正: インパクト後に自動停止
                let impactTimer = DispatchWorkItem { [weak self] in
                    print("⏰ インパクト推定タイマー発火 (トロフィー検出から2秒後)")
                    self?.stopRecording()
                }
                impactStopTimer = impactTimer
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: impactTimer)
                
                break
            }
        }
    }
    
    // MARK: - 🆕 Hip Center Calculation (getHipCenter の代替)
    private func calculateHipCenter(from pose: PoseData) -> CGPoint? {
        guard let leftHip = pose.joints[.leftHip],
              let rightHip = pose.joints[.rightHip] else {
            return nil
        }
        
        return CGPoint(
            x: (leftHip.x + rightHip.x) / 2,
            y: (leftHip.y + rightHip.y) / 2
        )
    }
    
    // MARK: - IMU Impact Detection
    private func detectImpactFromIMU() {
        guard let eventDet = getOrCreateEventDetector() else { return }
        guard impactEvent == nil else { return }
        
        // 🔧 修正: detectImpact(in:) に window を渡す
        let recentWindow = eventDet.getRecentIMU(duration: 2.0)
        
        if let impact = eventDet.detectImpact(in: recentWindow) {
            impactEvent = impact
            
            print("💥 Impact detected from IMU!")
            print("   - Peak Angular Velocity: \(String(format: "%.1f", impact.peakAngularVelocity)) rad/s")
            print("   - Confidence: \(String(format: "%.2f", impact.confidence))")
            
            // 🔧 追加: インパクト検出後、短時間で自動停止
            impactStopTimer?.cancel()
            let timer = DispatchWorkItem { [weak self] in
                print("⏰ インパクト検出後自動停止")
                self?.stopRecording()
            }
            impactStopTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timer)
        }
    }
    
    // MARK: - Analysis
    private func finalizeAnalysis() {
        print("\n=== 最終解析開始 ===")
        
        let metrics: ServeMetrics
        
        if let trophy = trophyPoseEvent {
            print("✅ Trophy pose: \(trophy)")
            
            let impact = impactEvent ?? createDummyImpactEvent()
            
            // ボール軌跡の取得
            var tossHistory: [BallDetection] = []
            if let tracker = ballTracker {
                let duration = max(0, trophy.timestamp - 1.0) // Trophy 1秒前から
                tossHistory = tracker.getRecentDetections(duration: duration)
                
                if tossHistory.isEmpty {
                    tossHistory = tracker.getDetectionHistory()
                }
                
                print("📊 Toss history: \(tossHistory.count) detections")
            }
            
            // 🎯 下半身貢献度の測定（骨盤上昇量）
            // トロフィーポーズの前後0.3秒ずつを測定範囲とする
            let windowBefore: Double = 0.3  // トロフィーの0.3秒前
            let windowAfter: Double = 0.3   // トロフィーの0.3秒後
            let rangeStart = trophy.timestamp - windowBefore
            let rangeEnd = trophy.timestamp + windowAfter
            
            print("\n📊 骨盤測定範囲:")
            print("   トロフィー時刻: \(String(format: "%.3f", trophy.timestamp))s")
            print("   測定範囲: \(String(format: "%.3f", rangeStart))s ~ \(String(format: "%.3f", rangeEnd))s")
            
            // 測定範囲内のポーズを抽出
            let posesInRange = poseHistory.filter { pose in
                pose.timestamp >= rangeStart && pose.timestamp <= rangeEnd
            }
            
            print("   範囲内のポーズ数: \(posesInRange.count)")
            
            // 範囲内で最も低い位置と最も高い位置を見つける
            var lowestY: CGFloat = .infinity
            var highestY: CGFloat = -.infinity
            var lowestPose: PoseData?
            var highestPose: PoseData?
            
            for pose in posesInRange {
                if let hipCenter = calculateHipCenter(from: pose) {
                    let hipY = hipCenter.y
                    
                    // 最も低い位置（Y座標が最大）
                    if hipY > lowestY {
                        lowestY = hipY
                        lowestPose = pose
                    }
                    
                    // 最も高い位置（Y座標が最小）
                    if hipY < highestY {
                        highestY = hipY
                        highestPose = pose
                    }
                }
            }
            
            // トロフィーポーズを基準点、最も高い位置をimpactPoseとして使用
            let impactPose: PoseData?
            let pelvisBasePose: PoseData?
            
            if let lowest = lowestPose, let highest = highestPose {
                // 最も低い位置を基準、最も高い位置との差を計算
                pelvisBasePose = lowest
                impactPose = highest
                print("📊 骨盤測定: 最低位置 y=\(String(format: "%.0f", lowestY)) → 最高位置 y=\(String(format: "%.0f", highestY))")
            } else {
                pelvisBasePose = nil
                impactPose = poseHistory.last
                print("⚠️ 測定範囲内にポーズが見つかりませんでした。最後のポーズを使用します。")
            }
            
            // 🔧 修正: pelvisRiseDetails の戻り値チェック（Optional unwrap）
            if let base = pelvisBasePose, let impact = impactPose {
                if let details = MetricsCalculator.pelvisRiseDetails(base, impact) {
                    if let hipTrophy = details.hipTrophy, let hipImpact = details.hipImpact {
                        print("\n📊 下半身貢献度（骨盤上昇量）:")
                        print("   測定範囲: トロフィーの\(windowBefore)秒前から\(windowAfter)秒後（計\(windowBefore + windowAfter)秒）")
                        print("   最低位置 骨盤座標: (x=\(String(format: "%.0f", hipTrophy.x)), y=\(String(format: "%.0f", hipTrophy.y)))")
                        print("   最高位置 骨盤座標: (x=\(String(format: "%.0f", hipImpact.x)), y=\(String(format: "%.0f", hipImpact.y)))")
                        print("   骨盤上昇量（ピクセル）: \(String(format: "%.1f", details.pixels)) px")
                        print("   ※理想範囲: 60~70 px")
                    } else {
                        print("⚠️ 骨盤座標の取得に失敗しました")
                    }
                } else {
                    print("⚠️ pelvisRiseDetailsの計算に失敗しました")
                }
            }
            
            metrics = MetricsCalculator.calculateMetrics(
                trophyPose: trophy,
                impactEvent: impact,
                tossHistory: tossHistory,
                imuHistory: watchIMUHistory,
                calibration: nil,
                courtCalibration: nil,
                impactPose: impactPose,
                pelvisBasePose: pelvisBasePose
            )
        } else {
            let duration = sessionStartTime.map { -$0.timeIntervalSinceNow } ?? maxSessionDuration
            let avgFPS = Double(frameCount) / duration
            metrics = calculatePartialMetrics(avgFPS: avgFPS)
        }
        
        print("✅ 解析完了 - スコア: \(metrics.totalScore)/100\n")
        state = .completed(metrics)
    }
    
    private func calculatePartialMetrics(avgFPS: Double) -> ServeMetrics {
        let elbowDeg: Double
        let armpitDeg: Double
        let leftTorso: Double
        let leftExt: Double
        
        if let trophy = trophyPoseEvent {
            elbowDeg = trophy.rightElbowAngle ?? 165.0
            armpitDeg = trophy.rightArmpitAngle ?? 90.0
            leftTorso = trophy.leftShoulderAngle ?? 65.0
            leftExt = trophy.leftElbowAngle ?? 170.0
        } else {
            var elbowAngles: [Double] = []
            for pose in poseHistory {
                if let elbow = PoseDetector.calculateElbowAngle(from: pose, isRight: true) {
                    elbowAngles.append(elbow)
                }
            }
            elbowDeg = elbowAngles.isEmpty ? 165.0 : elbowAngles.reduce(0, +) / Double(elbowAngles.count)
            armpitDeg = 90.0
            leftTorso = 65.0
            leftExt = 170.0
        }
        
        let pelvisRise = 30.0  // ダミー値（ピクセル）
        let bodyAxisD = 10.0
        let rfYaw = 15.0
        let rfPitch = 10.0
        let tossM = 0.30
        let wristDeg = 120.0

        let s1 = max(0, min(100, 100 - Int(abs(elbowDeg - 170) * 1.2)))
        let s2 = max(0, min(100, 100 - Int(abs(armpitDeg - 95) * 2.0)))
        let s3 = max(0, min(100, Int((pelvisRise / 60.0) * 100)))  // 60pxを基準
        let s4a = max(0, min(100, 100 - Int(abs(leftTorso - 65) * 2.0)))
        let s4b = max(0, min(100, 100 - Int(abs(leftExt - 170) * 1.0)))
        let s4 = Int((Double(s4a) * 0.4) + (Double(s4b) * 0.6))
        let s5 = max(0, min(100, 100 - Int(max(0.0, bodyAxisD - 5.0) * 5.0)))
        let s6y = max(0, min(100, 100 - Int(max(0.0, abs(rfYaw) - 15.0) * 3.0)))
        let s6p = max(0, min(100, 100 - Int(max(0.0, abs(rfPitch) - 10.0) * 4.0)))
        let s6 = (s6y + s6p) / 2
        let s7 = max(0, min(100, 100 - Int(max(0.0, abs(tossM - 0.4)) * 300.0)))
        let s8 = max(0, min(100, 100 - Int(max(0.0, abs(wristDeg - 170)) * 0.8)))

        // 総合スコア（8項目の単純平均）
        let scores = [s1, s2, s3, s4, s5, s6, s7, s8]
        let total = Double(scores.reduce(0, +)) / 8.0

        return ServeMetrics(
            elbowAngleDeg: elbowDeg,
            armpitAngleDeg: armpitDeg,
            pelvisRisePx: pelvisRise,
            leftArmTorsoAngleDeg: leftTorso,
            leftArmExtensionDeg: leftExt,
            bodyAxisDeviationDeg: bodyAxisD,
            racketFaceYawDeg: rfYaw,
            racketFacePitchDeg: rfPitch,
            tossForwardDistanceM: tossM,
            wristRotationDeg: wristDeg,
            score1_elbowAngle: s1,
            score2_armpitAngle: s2,
            score3_lowerBodyContribution: s3,
            score4_leftHandPosition: s4,
            score5_bodyAxisTilt: s5,
            score6_racketFaceAngle: s6,
            score7_tossPosition: s7,
            score8_wristwork: s8,
            totalScore: Int(total),
            timestamp: Date(),
            flags: ["partial_metrics","frames:\(frameCount)","poses:\(poseHistory.count)","fps:\(Int(avgFPS))"]
        )
    }

    
    // MARK: - Dummy Impact Event
    private func createDummyImpactEvent() -> ImpactEvent {
        let dummyTimestamp = (trophyPoseEvent?.timestamp ?? 0) + 0.5
        return ImpactEvent(
            timestamp: dummyTimestamp,
            monotonicMs: Int64(dummyTimestamp * 1000),
            peakAngularVelocity: 0.0,
            peakJerk: 0.0,
            spectralPower: 0.0,
            confidence: 0.0
        )
    }
    
    // MARK: - Utility
    func reset() {
        // 🔧 修正: タイマーをクリーンアップ
        autoStopTimer?.cancel()
        autoStopTimer = nil
        impactStopTimer?.cancel()
        impactStopTimer = nil
        
        // 🔧 追加: プレビューを停止
        videoCaptureManager?.stopPreview()
        videoCaptureManager?.stopRecording()
        videoCaptureManager = nil
        
        state = .idle
        frameCount = 0
        poseHistory.removeAll()
        watchIMUHistory.removeAll()
        trophyPoseEvent = nil
        impactEvent = nil
        sessionStartTime = nil
        detectedPose = nil
        detectedBall = nil
        trophyPoseDetected = false
        trophyAngles = nil
        pelvisPosition = nil
        frameDataHistory.removeAll()
        ballTracker = nil
        
        // 🔧 追加: 他のコンポーネントもクリーンアップ
        poseDetector = nil
        eventDetector = nil
    }
    
    func getPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        if videoCaptureManager == nil {
            let manager = VideoCaptureManager()
            manager.delegate = self
            videoCaptureManager = manager
        }
        
        return videoCaptureManager?.createPreviewLayer()
    }
    
    func getCurrentMetrics() -> ServeMetrics? {
        if case .completed(let metrics) = state {
            return metrics
        }
        return nil
    }
    
    private func addIMUSample(_ sample: ServeSample) {
        watchIMUHistory.append(sample)
        
        if let eventDet = getOrCreateEventDetector() {
            eventDet.addIMUSample(sample)
        }
        
        let maxHistory = 2000
        if watchIMUHistory.count > maxHistory {
            watchIMUHistory.removeFirst(watchIMUHistory.count - maxHistory)
        }
    }
}

// MARK: - Video Capture Delegate
extension VideoAnalyzer: VideoCaptureDelegate {
    func videoCaptureDidOutput(sampleBuffer: CMSampleBuffer, timestamp: Double) {
        // 🔧 修正: 録画中のみフレーム処理を行う
        if case .recording = state {
            processFrame(sampleBuffer: sampleBuffer, timestamp: timestamp)
        }
        
        // Update FPS (常時更新)
        if let manager = videoCaptureManager {
            DispatchQueue.main.async { [weak self] in
                self?.currentFPS = manager.currentFPS
            }
        }
    }
    
    func videoCaptureDidFail(error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.state = .error(error.localizedDescription)
        }
    }
    
    func videoCaptureDidStart() {
        print("✅ Video capture started")
    }
    
    func videoCaptureDidStop() {
        print("✅ Video capture stopped")
    }
}
