//
//  VideoAnalyzer.swift
//  TennisServeAnalyzer
//
//  Video analysis with Pose Detection + IMU Integration
//  🔧 修正: 簡潔なログ、頂点判定トロフィーポーズ、ボールx座標追加
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
    
    // 🔧 修正: 時系列データ保存（ボール座標をCGPointに）
    private struct FrameData {
        let timestamp: Double
        let angles: TrophyPoseAngles
        let ballPosition: CGPoint?  // 🔧 修正: ballYからballPositionに変更
    }
    private var frameDataHistory: [FrameData] = []
    
    // Watch IMU
    private var watchIMUHistory: [ServeSample] = []
    private var impactEvent: ImpactEvent?
    
    // Configuration
    private let maxSessionDuration: TimeInterval = 15.0
    private let poseDetectionInterval: Int = 2  // 2フレームごと (30回/秒)
    
    // MARK: - Initialization
    override init() {
        super.init()
        
        // Setup Watch connectivity
        setupWatchConnectivity()
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
    
    // MARK: - Watch Data Handlers
    private func handleWatchIMUSample(_ sample: ServeSample) {
        addIMUSample(sample)
    }
    
    private func handleWatchBatchData(_ samples: [ServeSample]) {
        for sample in samples {
            addIMUSample(sample)
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
    func startSession() {
        guard case .idle = state else { return }
        
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if granted {
                    self.startRecording()
                } else {
                    self.state = .error("カメラ権限が必要です")
                }
            }
        }
    }
    
    private func startRecording() {
        // Initialize video capture if needed
        if videoCaptureManager == nil {
            let manager = VideoCaptureManager()
            manager.delegate = self
            videoCaptureManager = manager
        }
        
        // Reset
        frameCount = 0
        poseHistory.removeAll()
        watchIMUHistory.removeAll()
        trophyPoseEvent = nil
        impactEvent = nil
        sessionStartTime = Date()
        trophyPoseDetected = false
        trophyAngles = nil
        frameDataHistory.removeAll()
        
        // Start Watch recording
        watchManager?.startWatchRecording()
        
        // Start
        state = .recording
        videoCaptureManager?.startRecording()
        
        print("=== 測定開始 ===")
        
        // Auto-stop
        DispatchQueue.main.asyncAfter(deadline: .now() + maxSessionDuration) { [weak self] in
            self?.stopRecording()
        }
    }
    
    func stopRecording() {
        guard case .recording = state else { return }
        
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
        
        var currentBallPosition: CGPoint? = nil  // 🔧 修正: CGPointに変更
        
        // Ball detection (毎フレーム)
        if let tracker = getOrCreateBallTracker() {
            if let ball = tracker.trackBall(from: sampleBuffer, timestamp: timestamp) {
                DispatchQueue.main.async { [weak self] in
                    self?.detectedBall = ball
                }
                currentBallPosition = ball.position  // 🔧 修正: 座標全体を保存
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
                        
                        let angles = TrophyPoseAngles(
                            rightElbowAngle: rightElbow,
                            rightArmpitAngle: rightArmpit,
                            leftElbowAngle: leftElbow,
                            leftShoulderAngle: leftShoulder
                        )
                        
                        // UI更新
                        DispatchQueue.main.async { [weak self] in
                            self?.trophyAngles = angles
                        }
                        
                        // データを保存
                        frameDataHistory.append(FrameData(
                            timestamp: timestamp,
                            angles: angles,
                            ballPosition: currentBallPosition  // 🔧 修正: CGPointで保存
                        ))
                        
                        // 🔧 修正: 骨格検出時に毎回ログ出力（x, y座標を表示）
                        let rightElbowStr = rightElbow.map { String(format: "%.1f", $0) } ?? "---"
                        let rightArmpitStr = rightArmpit.map { String(format: "%.1f", $0) } ?? "---"
                        let leftShoulderStr = leftShoulder.map { String(format: "%.1f", $0) } ?? "---"
                        let leftElbowStr = leftElbow.map { String(format: "%.1f", $0) } ?? "---"
                        
                        // 🔧 修正: x座標とy座標の両方を表示
                        let ballPosStr: String
                        if let pos = currentBallPosition {
                            ballPosStr = String(format: "x=%.0f, y=%.0f", pos.x, pos.y)
                        } else {
                            ballPosStr = "x=---, y=---"
                        }
                        
                        print("t=\(String(format: "%.2f", timestamp))s, 右肘:\(rightElbowStr)°, 右脇:\(rightArmpitStr)°, 左肩:\(leftShoulderStr)°, 左肘:\(leftElbowStr)°, ボール位置:(\(ballPosStr))")
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
                
                // Stop recording shortly after impact
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.stopRecording()
                }
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
        
        // 🔧 ボールの頂点（y座標最小）でトロフィーポーズを判定
        let ballDataWithAngles = frameDataHistory.filter { $0.ballPosition != nil }
        
        if !ballDataWithAngles.isEmpty {
            // y座標が最小（画面上部）= ボール頂点
            if let apexData = ballDataWithAngles.min(by: { $0.ballPosition!.y < $1.ballPosition!.y }) {
                let rightElbowStr = apexData.angles.rightElbowAngle.map { String(format: "%.1f", $0) } ?? "---"
                let rightArmpitStr = apexData.angles.rightArmpitAngle.map { String(format: "%.1f", $0) } ?? "---"
                let leftShoulderStr = apexData.angles.leftShoulderAngle.map { String(format: "%.1f", $0) } ?? "---"
                let leftElbowStr = apexData.angles.leftElbowAngle.map { String(format: "%.1f", $0) } ?? "---"
                
                // 🔧 修正: x座標とy座標の両方を表示
                let ballPosStr = String(format: "x=%.0f, y=%.0f", apexData.ballPosition!.x, apexData.ballPosition!.y)
                
                print("🏆 トロフィーポーズ（ボール頂点）:")
                print("   t=\(String(format: "%.2f", apexData.timestamp))s, 右肘:\(rightElbowStr)°, 右脇:\(rightArmpitStr)°, 左肩:\(leftShoulderStr)°, 左肘:\(leftElbowStr)°, ボール位置:(\(ballPosStr))")
                
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
            let impact = impactEvent ?? createDummyImpactEvent()
            let tossHistory = ballTracker?.getDetectionHistory() ?? []
            
            metrics = MetricsCalculator.calculateMetrics(
                trophyPose: trophy,
                impactEvent: impact,
                tossHistory: tossHistory,
                imuHistory: watchIMUHistory,
                calibration: nil,
                courtCalibration: nil,
                impactPose: nil
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
        
        let pelvisRise = 0.10
        let bodyAxisD = 10.0
        let rfYaw = 15.0
        let rfPitch = 10.0
        let tossM = 0.30
        let wristDeg = 120.0

        let s1 = max(0, min(100, 100 - Int(abs(elbowDeg - 170) * 1.2)))
        let s2 = max(0, min(100, 100 - Int(abs(armpitDeg - 95) * 2.0)))
        let s3 = max(0, min(100, Int((pelvisRise / 0.25) * 100)))
        let s4a = max(0, min(100, 100 - Int(abs(leftTorso - 65) * 2.0)))
        let s4b = max(0, min(100, 100 - Int(abs(leftExt - 170) * 1.0)))
        let s4 = Int((Double(s4a) * 0.4) + (Double(s4b) * 0.6))
        let s5 = max(0, min(100, 100 - Int(max(0.0, bodyAxisD - 5.0) * 5.0)))
        let s6y = max(0, min(100, 100 - Int(max(0.0, abs(rfYaw) - 15.0) * 3.0)))
        let s6p = max(0, min(100, 100 - Int(max(0.0, abs(rfPitch) - 10.0) * 4.0)))
        let s6 = (s6y + s6p) / 2
        let s7 = max(0, min(100, 100 - Int(max(0.0, abs(tossM - 0.4)) * 300.0)))
        let s8 = max(0, min(100, 100 - Int(max(0.0, abs(wristDeg - 170)) * 0.8)))

        let weights: [Double] = [10,10,20,10,15,10,10,15]
        let scores = [s1,s2,s3,s4,s5,s6,s7,s8].map { Double($0) }
        let total = zip(scores, weights).reduce(0.0) { $0 + $1.0 * $1.1 / 100.0 }

        return ServeMetrics(
            elbowAngleDeg: elbowDeg,
            armpitAngleDeg: armpitDeg,
            pelvisRiseM: pelvisRise,
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
        videoCaptureManager?.stopRecording()
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
        frameDataHistory.removeAll()
        ballTracker = nil
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
    
    func addIMUSample(_ sample: ServeSample) {
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
        processFrame(sampleBuffer: sampleBuffer, timestamp: timestamp)
        
        // Update FPS
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
    }
    
    func videoCaptureDidStop() {
    }
}
