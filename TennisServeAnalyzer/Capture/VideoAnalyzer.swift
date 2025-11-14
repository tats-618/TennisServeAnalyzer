//
//  VideoAnalyzer.swift
//  TennisServeAnalyzer
//
//  Video analysis with Pose Detection + IMU Integration
//  🔧 修正: アプリ起動時からカメラプレビュー表示
//

import Foundation
import AVFoundation
import CoreMedia
import Combine

// MARK: - Analysis State
enum AnalysisState {
    case idle
    case recording
    case analyzing
    case completed(ServeMetrics)
    case error(String)
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
        
        // 🔧 追加: 初期化時にカメラ権限をリクエスト
        requestCameraPermission()
    }
    
    // MARK: - Camera Permission
    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    print("✅ Camera permission granted")
                    // 権限があればプレビューを準備
                    self?.prepareCameraPreview()
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
        
        // プレビューレイヤーを準備（録画は開始しない）
        _ = self.getPreviewLayer()
        
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
        guard case .idle = state else { return }
        
        print("🎬 Starting recording immediately...")
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
            self?.performAnalysis()
        }
    }
    
    // MARK: - Frame Processing
    private func processFrame(sampleBuffer: CMSampleBuffer, timestamp: Double) {
        guard case .recording = state else { return }
        
        frameCount += 1
        
        var currentBallPosition: CGPoint? = nil
        
        // Ball detection (毎フレーム)
        if let tracker = getOrCreateBallTracker() {
            if let ball = tracker.trackBall(from: sampleBuffer, timestamp: timestamp) {
                DispatchQueue.main.async { [weak self] in
                    self?.detectedBall = ball
                }
                currentBallPosition = ball.position
            }
        }
        
        // Pose detection (every N frames)
        if frameCount % poseDetectionInterval == 0 {
            if let detector = getOrCreatePoseDetector() {
                if let pose = detector.detectPose(from: sampleBuffer, timestamp: timestamp) {
                    DispatchQueue.main.async { [weak self] in
                        self?.detectedPose = pose
                    }
                    
                    // Store if valid
                    if pose.isValid {
                        poseHistory.append(pose)
                        
                        // 角度を計算
                        let rightElbow = PoseDetector.calculateElbowAngle(from: pose, isRight: true)
                        let rightArmpit = PoseDetector.armpitAngle(pose, side: .right)
                        let leftElbow = PoseDetector.calculateElbowAngle(from: pose, isRight: false)
                        let leftShoulder = PoseDetector.leftHandAngles(pose)?.torso
                        
                        // 骨盤中心座標を計算
                        let pelvisPosition: CGPoint?
                        if let rHip = pose.joints[.rightHip], let lHip = pose.joints[.leftHip] {
                            pelvisPosition = CGPoint(x: (rHip.x + lHip.x) / 2, y: (rHip.y + lHip.y) / 2)
                        } else {
                            pelvisPosition = nil
                        }
                        
                        let angles = TrophyPoseAngles(
                            rightElbowAngle: rightElbow,
                            rightArmpitAngle: rightArmpit,
                            leftElbowAngle: leftElbow,
                            leftShoulderAngle: leftShoulder
                        )
                        
                        // UI更新
                        DispatchQueue.main.async { [weak self] in
                            self?.trophyAngles = angles
                            self?.pelvisPosition = pelvisPosition
                        }
                        
                        // データを保存
                        frameDataHistory.append(FrameData(
                            timestamp: timestamp,
                            angles: angles,
                            ballPosition: currentBallPosition,
                            pelvisPosition: pelvisPosition
                        ))
                        
                        // ログ出力
                        let rightElbowStr = rightElbow.map { String(format: "%.1f", $0) } ?? "---"
                        let rightArmpitStr = rightArmpit.map { String(format: "%.1f", $0) } ?? "---"
                        let leftShoulderStr = leftShoulder.map { String(format: "%.1f", $0) } ?? "---"
                        let leftElbowStr = leftElbow.map { String(format: "%.1f", $0) } ?? "---"
                        
                        let ballPosStr: String
                        if let pos = currentBallPosition {
                            ballPosStr = String(format: "x=%.0f, y=%.0f", pos.x, pos.y)
                        } else {
                            ballPosStr = "x=---, y=---"
                        }
                        
                        let pelvisPosStr: String
                        if let pos = pelvisPosition {
                            pelvisPosStr = String(format: "x=%.0f, y=%.0f", pos.x, pos.y)
                        } else {
                            pelvisPosStr = "x=---, y=---"
                        }
                        
                        print("t=\(String(format: "%.2f", timestamp))s, 右肘:\(rightElbowStr)°, 右脇:\(rightArmpitStr)°, 左肩:\(leftShoulderStr)°, 左肘:\(leftElbowStr)°, ボール:(\(ballPosStr)), 骨盤:(\(pelvisPosStr))")
                    }
                }
            }
        }
        
        // Impact検出
        detectImpactFromIMU()
    }
    
    // MARK: - Impact Detection from IMU
    private func detectImpactFromIMU() {
        guard impactEvent == nil else { return }
        guard watchIMUHistory.count >= 50 else { return }
        
        if let eventDet = getOrCreateEventDetector() {
            let recentIMU = Array(watchIMUHistory.suffix(100))
            
            if let impact = eventDet.detectImpact(in: recentIMU) {
                impactEvent = impact
                
                // 🔧 修正: 既存のインパクトタイマーをキャンセル
                impactStopTimer?.cancel()
                
                let impactTimer = DispatchWorkItem { [weak self] in
                    print("🎯 インパクト検出による停止")
                    self?.stopRecording()
                }
                impactStopTimer = impactTimer
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: impactTimer)
            }
        }
    }
    
    // MARK: - Analysis
    private func performAnalysis() {
        print("\n=== 測定終了 ===")
        
        guard poseHistory.count >= 3 else {
            state = .error("骨格データが不足しています")
            return
        }
        
        // ボールの頂点でトロフィーポーズを判定
        let ballDataWithAngles = frameDataHistory.filter { $0.ballPosition != nil }
        
        if !ballDataWithAngles.isEmpty {
            // y座標が最小（画面上部）= ボール頂点
            if let apexData = ballDataWithAngles.min(by: { $0.ballPosition!.y < $1.ballPosition!.y }) {
                let rightElbowStr = apexData.angles.rightElbowAngle.map { String(format: "%.1f", $0) } ?? "---"
                let rightArmpitStr = apexData.angles.rightArmpitAngle.map { String(format: "%.1f", $0) } ?? "---"
                let leftShoulderStr = apexData.angles.leftShoulderAngle.map { String(format: "%.1f", $0) } ?? "---"
                let leftElbowStr = apexData.angles.leftElbowAngle.map { String(format: "%.1f", $0) } ?? "---"
                
                let ballPosStr = String(format: "x=%.0f, y=%.0f", apexData.ballPosition!.x, apexData.ballPosition!.y)
                
                let pelvisPosStr: String
                if let pos = apexData.pelvisPosition {
                    pelvisPosStr = String(format: "x=%.0f, y=%.0f", pos.x, pos.y)
                } else {
                    pelvisPosStr = "x=---, y=---"
                }
                
                print("🏆 トロフィーポーズ（ボール頂点）:")
                print("   t=\(String(format: "%.2f", apexData.timestamp))s, 右肘:\(rightElbowStr)°, 右脇:\(rightArmpitStr)°, 左肩:\(leftShoulderStr)°, 左肘:\(leftElbowStr)°")
                print("   ボール位置:(\(ballPosStr)), 骨盤位置:(\(pelvisPosStr))")
                
                // トロフィーポーズイベントを頂点の実際の角度で作成
                if let nearestPose = poseHistory.min(by: { abs($0.timestamp - apexData.timestamp) < abs($1.timestamp - apexData.timestamp) }) {
                    trophyPoseEvent = TrophyPoseEvent(
                        timestamp: apexData.timestamp,
                        pose: nearestPose,
                        tossApex: (time: apexData.timestamp, height: apexData.ballPosition!.y),
                        confidence: 1.0,
                        elbowAngle: apexData.angles.rightElbowAngle,
                        shoulderAbduction: nil as Double?,
                        isValid: true,
                        rightElbowAngle: apexData.angles.rightElbowAngle,
                        rightArmpitAngle: apexData.angles.rightArmpitAngle,
                        leftShoulderAngle: apexData.angles.leftShoulderAngle,
                        leftElbowAngle: apexData.angles.leftElbowAngle
                    )
                }
                
                DispatchQueue.main.async { [weak self] in
                    self?.trophyPoseDetected = true
                    self?.trophyAngles = apexData.angles
                }
            }
        } else {
            print("⚠️ ボールデータが不足しているため、トロフィーポーズを特定できませんでした")
        }
        
        // メトリクス計算
        let metrics: ServeMetrics
        
        if let trophy = trophyPoseEvent {
            let impact = impactEvent ?? self.createDummyImpactEvent()
            let tossHistory = ballTracker?.getDetectionHistory() ?? []
            
            // トロフィーポーズの1秒前から4秒後の範囲で骨盤上昇量を測定
            let trophyTime = trophy.timestamp
            let windowBefore = 1.0
            let windowAfter = 4.0
            
            // トロフィーポーズの1秒前から4秒後の範囲のポーズをフィルタリング
            let windowPoses = poseHistory.filter { pose in
                let timeDiff = pose.timestamp - trophyTime
                return timeDiff >= -windowBefore && timeDiff <= windowAfter
            }
            
            // 骨盤が最も低い位置（Y座標が最大）と最も高い位置（Y座標が最小）を検出
            var lowestPose: PoseData?
            var highestPose: PoseData?
            var lowestY: CGFloat = 0
            var highestY: CGFloat = CGFloat.greatestFiniteMagnitude
            
            if !windowPoses.isEmpty {
                for pose in windowPoses {
                    guard let rH = pose.joints[.rightHip], let lH = pose.joints[.leftHip] else {
                        continue
                    }
                    let hipY = (rH.y + lH.y) / 2.0
                    
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
            
            // 骨盤上昇量の詳細情報を出力
            if let base = pelvisBasePose, let impact = impactPose {
                if let details = MetricsCalculator.pelvisRiseDetails(base, impact) {
                    print("\n📊 下半身貢献度（骨盤上昇量）:")
                    print("   測定範囲: トロフィーの\(windowBefore)秒前から\(windowAfter)秒後（計\(windowBefore + windowAfter)秒）")
                    if let hipTrophy = details.hipTrophy, let hipImpact = details.hipImpact {
                        print("   最低位置 骨盤座標: (x=\(String(format: "%.0f", hipTrophy.x)), y=\(String(format: "%.0f", hipTrophy.y)))")
                        print("   最高位置 骨盤座標: (x=\(String(format: "%.0f", hipImpact.x)), y=\(String(format: "%.0f", hipImpact.y)))")
                        print("   骨盤上昇量（ピクセル）: \(String(format: "%.1f", details.pixels)) px")
                        print("   ※理想範囲: 60~70 px")
                    }
                } else {
                    print("⚠️ 骨盤座標の取得に失敗しました")
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
        
        // 🔧 追加: リセット後にカメラプレビューを再準備
        prepareCameraPreview()
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
