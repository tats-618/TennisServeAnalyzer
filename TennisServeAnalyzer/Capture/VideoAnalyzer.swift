//
//  VideoAnalyzer.swift (⚡️ BALL DETECTION OPTIMIZED v3)
//  TennisServeAnalyzer
//
//  🔧 v3.0 修正内容:
//  - screenSize取得、baselineX宣言順序修正
//  - トス座標不一致修正（tossApexX, filteredBalls追加）
//

import Foundation
import AVFoundation
import CoreMedia
import Combine

// MARK: - Analysis State
enum AnalysisState {
    case idle
    case setupCamera
    case recording
    case analyzing
    case completed(ServeMetrics)
    case sessionSummary([ServeMetrics])
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
    
    // セッション管理
    private var sessionMetrics: [ServeMetrics] = []
    private var sessionStartDate: Date?
    
    // タイマー管理
    private var autoStopTimer: DispatchWorkItem?
    private var impactStopTimer: DispatchWorkItem?
    
    // Watch connectivity
    private var watchManager: WatchConnectivityManager?
    @Published var isWatchConnected: Bool = false
    @Published var watchSamplesReceived: Int = 0
    
    // Components
    private var videoCaptureManager: VideoCaptureManager?
    
    // スレッドセーフな初期化
    private var _poseDetector: PoseDetector?
    private let poseDetectorLock = NSLock()
    
    private var _eventDetector: EventDetector?
    private let eventDetectorLock = NSLock()
    
    private var _ballTracker: BallTracker?
    private let ballTrackerLock = NSLock()
    
    // Session data
    private var frameCount: Int = 0
    private var poseHistory: [PoseData] = []
    private var trophyPoseEvent: TrophyPoseEvent?
    private var measurementStartTime: Date?
    
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
    
    // 非同期処理用のキュー
    private let processingQueue = DispatchQueue(
        label: "com.tennisserve.processing",
        qos: .userInitiated,
        attributes: .concurrent
    )
    
    private let dataQueue = DispatchQueue(
        label: "com.tennisserve.data",
        qos: .userInitiated
    )
    
    // Configuration
    private let maxSessionDuration: TimeInterval = 60.0
    private let poseDetectionInterval: Int = 6        // 姿勢: 5フレームごと
    private let ballDetectionInterval: Int = 4       // ボール: 毎フレーム
    
    // パフォーマンス測定
    private var actualBallDetections: Int = 0
    private var predictedBallDetections: Int = 0
    
    // MARK: - Initialization
    override init() {
        super.init()
        
        setupWatchConnectivity()
        requestCameraPermission()
        
        print("📱 VideoAnalyzer initialized (Ball detection: every \(ballDetectionInterval) frames)")
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
        
        watchManager?.$isWatchConnected
            .receive(on: DispatchQueue.main)
            .assign(to: &$isWatchConnected)
        
        watchManager?.$receivedSamplesCount
            .receive(on: DispatchQueue.main)
            .assign(to: &$watchSamplesReceived)
        
        watchManager?.onIMUDataReceived = { [weak self] sample in
            self?.handleWatchIMUSample(sample)
        }
        
        watchManager?.onBatchDataReceived = { [weak self] samples in
            self?.handleWatchBatchData(samples)
        }
    }
    
    // MARK: - Session Management Methods
    
    func retryMeasurement() {
        print("🔄 Retrying measurement...")
        
        autoStopTimer?.cancel()
        autoStopTimer = nil
        impactStopTimer?.cancel()
        impactStopTimer = nil
        
        if case .completed(let metrics) = state {
            sessionMetrics.append(metrics)
            print("✅ Added metrics to session (total: \(sessionMetrics.count))")
        }
        
        state = .setupCamera
        prepareCameraPreview()
    }
    
    func endSession() {
        print("🏁 Ending session...")
        
        autoStopTimer?.cancel()
        autoStopTimer = nil
        impactStopTimer?.cancel()
        impactStopTimer = nil
        
        if case .completed(let metrics) = state {
            sessionMetrics.append(metrics)
            print("✅ Added final metrics to session")
        }
        
        guard !sessionMetrics.isEmpty else {
            print("⚠️ No metrics in session, returning to idle")
            state = .idle
            return
        }
        
        print("📊 Session summary with \(sessionMetrics.count) serves")
        state = .sessionSummary(sessionMetrics)
    }
    
    func resetSession() {
        print("🔄 Resetting entire session...")
        sessionMetrics.removeAll()
        sessionStartDate = nil
        reset()
    }
    
    // MARK: - Camera Setup Flow
    func setupCamera() {
        guard case .idle = state else { return }
        
        print("📷 Setting up camera with baseline overlay...")
        
        if sessionStartDate == nil {
            sessionStartDate = Date()
            print("📅 Session started at \(sessionStartDate!)")
        }
        
        prepareCameraPreview()
        state = .setupCamera
    }
    
    // MARK: - Camera Preview Preparation
    func prepareCameraPreview() {
        print("📷 Preparing camera preview...")
        
        videoCaptureManager?.stopRecording()
        videoCaptureManager = nil
        
        let manager = VideoCaptureManager()
        manager.delegate = self
        videoCaptureManager = manager
        
        _ = self.getPreviewLayer()
        
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
    
    // MARK: - Thread-Safe Lazy Initialization
    
    private func getOrCreatePoseDetector() -> PoseDetector {
        poseDetectorLock.lock()
        defer { poseDetectorLock.unlock() }
        
        if _poseDetector == nil {
            print("🆕 Initializing PoseDetector (first time)")
            _poseDetector = PoseDetector()
        }
        return _poseDetector!
    }
    
    private func getOrCreateEventDetector() -> EventDetector {
        eventDetectorLock.lock()
        defer { eventDetectorLock.unlock() }
        
        if _eventDetector == nil {
            print("🆕 Initializing EventDetector (first time)")
            _eventDetector = EventDetector()
        }
        return _eventDetector!
    }
    
    private func getOrCreateBallTracker() -> BallTracker {
        ballTrackerLock.lock()
        defer { ballTrackerLock.unlock() }
        
        if _ballTracker == nil {
            print("🆕 Initializing BallTracker (first time)")
            _ballTracker = BallTracker()
        }
        return _ballTracker!
    }
    
    // MARK: - Main Flow
    func startRecording() {
        guard case .setupCamera = state else {
            print("⚠️ Cannot start recording from state: \(state)")
            return
        }
        
        print("🎬 Starting recording from camera setup...")
        startRecordingInternal()
    }
    
    private func startRecordingInternal() {
        videoCaptureManager?.stopRecording()
        videoCaptureManager = nil
        
        let manager = VideoCaptureManager()
        manager.delegate = self
        videoCaptureManager = manager
        
        autoStopTimer?.cancel()
        autoStopTimer = nil
        impactStopTimer?.cancel()
        impactStopTimer = nil
        
        // Reset data
        dataQueue.async { [weak self] in
            guard let self = self else { return }
            self.frameCount = 0
            self.poseHistory.removeAll()
            self.watchIMUHistory.removeAll()
            self.trophyPoseEvent = nil
            self.impactEvent = nil
            self.frameDataHistory.removeAll()
            
            // パフォーマンス測定リセット
            self.actualBallDetections = 0
            self.predictedBallDetections = 0
            
            // 🆕 BallTracker の履歴もリセット（インスタンスを作り直す）
            self.ballTrackerLock.lock()
            self._ballTracker = nil
            self.ballTrackerLock.unlock()
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.trophyPoseDetected = false
            self?.trophyAngles = nil
            self?.pelvisPosition = nil
        }
        
        // AI components を事前初期化
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            print("⚙️ Pre-initializing AI components...")
            _ = self.getOrCreatePoseDetector()
            _ = self.getOrCreateBallTracker()
            _ = self.getOrCreateEventDetector()
            print("✅ AI components ready")
        }
        
        measurementStartTime = Date()
        
        watchManager?.startWatchRecording()
        
        state = .recording
        videoCaptureManager?.startRecording()
        
        print("=== 測定開始 ===")
        print("⚙️ Ball detection: every \(ballDetectionInterval) frames (interval optimization)")
        
        let timerWorkItem = DispatchWorkItem { [weak self] in
            print("⏰ 自動停止タイマー発火")
            self?.stopRecording()
        }
        autoStopTimer = timerWorkItem
        
        DispatchQueue.main.asyncAfter(deadline: .now() + maxSessionDuration, execute: timerWorkItem)
    }
    
    func stopRecording() {
        guard case .recording = state else { return }
        
        print("🛑 停止処理開始...")
        
        autoStopTimer?.cancel()
        autoStopTimer = nil
        impactStopTimer?.cancel()
        impactStopTimer = nil
        
        // パフォーマンス統計を出力
        dataQueue.async { [weak self] in
            guard let self = self else { return }
            let total = self.actualBallDetections + self.predictedBallDetections
            if total > 0 {
                let actualPercent = Double(self.actualBallDetections) / Double(total) * 100
                let predictPercent = Double(self.predictedBallDetections) / Double(total) * 100
                print("📊 Ball Detection Stats:")
                print("   Actual detections: \(self.actualBallDetections) (\(String(format: "%.1f", actualPercent))%)")
                print("   Predicted: \(self.predictedBallDetections) (\(String(format: "%.1f", predictPercent))%)")
                print("   Total: \(total)")
            }
        }
        
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.watchManager?.stopWatchRecording()
            self.videoCaptureManager?.stopRecording()
            
            DispatchQueue.main.async {
                self.state = .analyzing
                print("✅ 停止処理完了、解析開始...")
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.finalizeAnalysis()
            }
        }
    }
    
    // MARK: - Frame Processing (ボール検出最適化版)
    private func processFrame(sampleBuffer: CMSampleBuffer, timestamp: Double) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.dataQueue.async {
                self.frameCount += 1
            }
            
            var currentPose: PoseData?
            var currentBall: BallDetection?
            
            // Pose detection (5フレームごと)
            let shouldDetectPose = self.dataQueue.sync {
                self.frameCount % self.poseDetectionInterval == 0
            }
            
            if shouldDetectPose {
                let poseDet = self.getOrCreatePoseDetector()
                if let pose = poseDet.detectPose(from: sampleBuffer, timestamp: timestamp) {
                    currentPose = pose
                    
                    self.dataQueue.async {
                        self.poseHistory.append(pose)
                    }
                    
                    DispatchQueue.main.async { [weak self] in
                        self?.detectedPose = pose
                    }
                }
            }
            
            // Ball detection (毎フレーム + 予測で補完)
            let shouldDetectBall = self.dataQueue.sync {
                self.frameCount % self.ballDetectionInterval == 0
            }
            
            let tracker = self.getOrCreateBallTracker()
            
            if shouldDetectBall {
                // 実際のYOLO検出
                if let ball = tracker.trackBall(from: sampleBuffer, timestamp: timestamp) {
                    currentBall = ball
                    
                    self.dataQueue.async {
                        self.actualBallDetections += 1
                    }
                    
                    DispatchQueue.main.async { [weak self] in
                        self?.detectedBall = ball
                    }
                }
            } else {
                // Kalman予測のみ
                if let ball = tracker.predictBallPosition(timestamp: timestamp) {
                    currentBall = ball
                    
                    self.dataQueue.async {
                        self.predictedBallDetections += 1
                    }
                    
                    DispatchQueue.main.async { [weak self] in
                        self?.detectedBall = ball
                    }
                }
            }
            
            self.logFrameDetails(timestamp: timestamp, pose: currentPose, ball: currentBall)
        }
    }
    
    // MARK: - 詳細ログ出力
    private func logFrameDetails(timestamp: Double, pose: PoseData?, ball: BallDetection?) {
        guard let pose = pose else { return }
        
        let rightElbow = PoseDetector.calculateElbowAngle(from: pose, isRight: true)
        let rightArmpit = PoseDetector.armpitAngle(pose, side: .right)
        let leftAngles = PoseDetector.leftHandAngles(pose)
        let leftShoulder = leftAngles?.torso
        let leftElbow = leftAngles?.extension
        
        let ballStr: String
        if let ball = ball {
            ballStr = String(format: "x=%.0f, y=%.0f", ball.position.x, ball.position.y)
        } else {
            ballStr = "x=---, y=---"
        }
        
        let pelvisStr: String
        if let pelvisPos = calculateHipCenter(from: pose) {
            pelvisStr = String(format: "x=%.0f, y=%.0f", pelvisPos.x, pelvisPos.y)
        } else {
            pelvisStr = "x=---, y=---"
        }
        
        let elbowStr = rightElbow != nil ? String(format: "%.1f°", rightElbow!) : "---°"
        let armpitStr = rightArmpit != nil ? String(format: "%.1f°", rightArmpit!) : "---°"
        let leftShoulderStr = leftShoulder != nil ? String(format: "%.1f°", leftShoulder!) : "---°"
        let leftElbowStr = leftElbow != nil ? String(format: "%.1f°", leftElbow!) : "---°"
        
        print("t=\(String(format: "%.2f", timestamp))s, 右肘:\(elbowStr), 右脇:\(armpitStr), 左肩:\(leftShoulderStr), 左肘:\(leftElbowStr), ボール:(\(ballStr)), 骨盤:(\(pelvisStr))")
    }
    
    // MARK: - Hip Center Calculation
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
    
    // MARK: - Outlier Filter for Ball Detection
    private func filterOutliers(from balls: [BallDetection], screenSize: CGSize) -> [BallDetection] {
        guard balls.count > 2 else { return balls }
        
        let sortedBalls = balls.sorted { $0.timestamp < $1.timestamp }
        
        var filtered: [BallDetection] = []
        
        // 🔧 動的に取得
        let screenWidth: CGFloat = screenSize.width
        let screenHeight: CGFloat = screenSize.height
        
        print("📏 Filter settings: width=\(Int(screenWidth))px, height=\(Int(screenHeight))px")
        print("   Left exclusion: <\(Int(screenWidth * 0.2))px")
        print("   Lower half: >\(Int(screenHeight / 2))px")
        
        let leftExclusionZone: CGFloat = screenWidth * 0.2   // 左20%
        let lowerHalfThreshold: CGFloat = screenHeight / 2   // 下半分
        let maxDistancePerFrame: CGFloat = 100               // 100px固定
        
        for (index, ball) in sortedBalls.enumerated() {
            var shouldInclude = true
            
            // 1. 画面の左20%を除外
            if ball.position.x < leftExclusionZone {
                print("🚫 外れ値除外（左20%）: t=\(String(format: "%.2f", ball.timestamp))s, x=\(Int(ball.position.x)) (< \(Int(leftExclusionZone)))")
                shouldInclude = false
            }
            
            // 2. 画面の下半分を除外
            if ball.position.y > lowerHalfThreshold {
                print("🚫 外れ値除外（下半分）: t=\(String(format: "%.2f", ball.timestamp))s, y=\(Int(ball.position.y)) (> \(Int(lowerHalfThreshold)))")
                shouldInclude = false
            }
            
            // 3. 前フレームとの距離チェック
            if index > 0 && shouldInclude {
                let prevBall = sortedBalls[index - 1]
                let distance = sqrt(
                    pow(ball.position.x - prevBall.position.x, 2) +
                    pow(ball.position.y - prevBall.position.y, 2)
                )
                
                if distance > maxDistancePerFrame {
                    print("🚫 外れ値除外（移動距離）: t=\(String(format: "%.2f", ball.timestamp))s, 距離=\(Int(distance))px (> \(Int(maxDistancePerFrame)))")
                    shouldInclude = false
                }
            }
            
            if shouldInclude {
                filtered.append(ball)
            }
        }
        
        print("📊 外れ値フィルター: \(balls.count)件 → \(filtered.count)件 (除外: \(balls.count - filtered.count)件)")
        
        return filtered
    }
    
    // MARK: - Trophy Pose Detection from Ball Apex
    private func detectTrophyPoseFromBallApex() -> TrophyPoseEvent? {
        let tracker = getOrCreateBallTracker()
        
        let ballHistory = tracker.getDetectionHistory()
        guard !ballHistory.isEmpty else {
            print("⚠️ ボール検出履歴がありません")
            return nil
        }
        
        print("📊 ボール検出数（フィルター前）: \(ballHistory.count)")
        
        // 🔧 修正: 画面サイズを取得
        let poseHistoryCopy = dataQueue.sync { self.poseHistory }
        guard let firstPose = poseHistoryCopy.first else {
            print("⚠️ ポーズ履歴がないため画面サイズが不明")
            return nil
        }
        
        let screenSize = CGSize(width: firstPose.imageSize.width, height: firstPose.imageSize.height)
        let filteredBalls = filterOutliers(from: ballHistory, screenSize: screenSize)
        
        guard !filteredBalls.isEmpty else {
            print("⚠️ フィルター後にボール検出がありません")
            return nil
        }
        
        print("📊 ボール検出数（フィルター後）: \(filteredBalls.count)")
        
        var apexBall: BallDetection?
        var minY: CGFloat = .infinity
        
        for ball in filteredBalls {
            if ball.position.y < minY {
                minY = ball.position.y
                apexBall = ball
            }
        }
        
        guard let apex = apexBall else {
            print("⚠️ ボール頂点が見つかりませんでした")
            return nil
        }
        
        // 🔧 修正: x座標も表示
        print("📊 ボール頂点: t=\(String(format: "%.2f", apex.timestamp))s, x=\(String(format: "%.0f", apex.position.x)), y=\(String(format: "%.0f", apex.position.y))")
        print("🎯 トス診断: ボールX=\(Int(apex.position.x))px")
        
        guard !poseHistoryCopy.isEmpty else {
            print("⚠️ ポーズ履歴がありません")
            return nil
        }
        
        var closestPose: PoseData?
        var minTimeDiff: Double = .infinity
        
        for pose in poseHistoryCopy {
            let timeDiff = abs(pose.timestamp - apex.timestamp)
            if timeDiff < minTimeDiff {
                minTimeDiff = timeDiff
                closestPose = pose
            }
        }
        
        guard let trophyPose = closestPose else {
            print("⚠️ トロフィーポーズが見つかりませんでした")
            return nil
        }
        
        print("📊 トロフィーポーズ: t=\(String(format: "%.2f", trophyPose.timestamp))s (時間差: \(String(format: "%.3f", minTimeDiff))s)")
        
        let rightElbow = PoseDetector.calculateElbowAngle(from: trophyPose, isRight: true)
        let rightArmpit = PoseDetector.armpitAngle(trophyPose, side: .right)
        let leftAngles = PoseDetector.leftHandAngles(trophyPose)
        let leftShoulder = leftAngles?.torso
        let leftElbow = leftAngles?.extension
        
        let tossApexTuple: (time: Double, height: CGFloat)? = (time: apex.timestamp, height: apex.position.y)
        
        let trophyEvent = TrophyPoseEvent(
            timestamp: trophyPose.timestamp,
            pose: trophyPose,
            tossApex: tossApexTuple,
            tossApexX: apex.position.x,               // ← 4番目
            filteredBalls: filteredBalls,             // ← 5番目
            confidence: trophyPose.averageConfidence, // ← 6番目
            elbowAngle: rightElbow,
            shoulderAbduction: nil,
            isValid: true,
            rightElbowAngle: rightElbow,
            rightArmpitAngle: rightArmpit,
            leftShoulderAngle: leftShoulder,
            leftElbowAngle: leftElbow
        )
        
        return trophyEvent
    }
    
    // MARK: - IMU Impact Detection
    private func detectImpactFromIMU() {
        let eventDet = getOrCreateEventDetector()
        guard impactEvent == nil else { return }
        
        let recentWindow = eventDet.getRecentIMU(duration: 2.0)
        
        if let impact = eventDet.detectImpact(in: recentWindow) {
            impactEvent = impact
            
            print("💥 Impact detected from IMU!")
            print("   - Peak Angular Velocity: \(String(format: "%.1f", impact.peakAngularVelocity)) rad/s")
            print("   - Confidence: \(String(format: "%.2f", impact.confidence))")
        }
    }
    
    // MARK: - Analysis (非同期実行)
    private func finalizeAnalysis() {
        print("=== 測定終了 ===")
        print("\n=== 最終解析開始 ===")
        
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            let metrics: ServeMetrics
            
            let trophyResult = self.detectTrophyPoseFromBallApex()
            
            if let trophy = trophyResult {
                let elbowStr = trophy.rightElbowAngle != nil ? String(format: "%.1f°", trophy.rightElbowAngle!) : "---°"
                let armpitStr = trophy.rightArmpitAngle != nil ? String(format: "%.1f°", trophy.rightArmpitAngle!) : "---°"
                let leftShoulderStr = trophy.leftShoulderAngle != nil ? String(format: "%.1f°", trophy.leftShoulderAngle!) : "---°"
                let leftElbowStr = trophy.leftElbowAngle != nil ? String(format: "%.1f°", trophy.leftElbowAngle!) : "---°"
                
                let ballStr: String
                if let apex = trophy.tossApex {
                    ballStr = String(format: "x=---, y=%.0f", apex.height)
                } else {
                    ballStr = "x=---, y=---"
                }
                
                let pelvisStr: String
                if let pelvisPos = self.calculateHipCenter(from: trophy.pose) {
                    pelvisStr = String(format: "x=%.0f, y=%.0f", pelvisPos.x, pelvisPos.y)
                } else {
                    pelvisStr = "x=---, y=---"
                }
                
                // 🔧 修正: baselineXを先に計算
                let frameWidth = trophy.pose.imageSize.width
                let baselineX = frameWidth / 2.0
                print("📏 Frame width: \(Int(frameWidth))px, Baseline X: \(Int(baselineX))px")
                
                // 🔧 修正: trophyEventから正しいトス座標を取得
                if let tossX = trophy.tossApexX {
                    let offset = Double(tossX) - baselineX
                    print("🎯 トス計算: ボールX=\(Int(tossX))px, 基準線=\(Int(baselineX))px, オフセット=\(offset >= 0 ? "+" : "")\(Int(offset))px")
                } else {
                    print("⚠️ トス位置の座標が取得できませんでした")
                }
                
                print("🏆 トロフィーポーズ: t=\(String(format: "%.2f", trophy.timestamp))s, 右肘:\(elbowStr), 右脇:\(armpitStr), 左肩:\(leftShoulderStr), 左肘:\(leftElbowStr), ボール:(\(ballStr)), 骨盤:(\(pelvisStr))")
                
                let impact = self.impactEvent ?? self.createDummyImpactEvent()
                
                let windowBefore: Double = 0.2
                let windowAfter: Double = 0.6
                let rangeStart = trophy.timestamp - windowBefore
                let rangeEnd = trophy.timestamp + windowAfter
                
                print("📊 骨盤測定区間: t=\(String(format: "%.2f", rangeStart))s ～ \(String(format: "%.2f", rangeEnd))s")
                
                let poseHistoryCopy = self.dataQueue.sync { self.poseHistory }
                let posesInRange = poseHistoryCopy.filter { pose in
                    pose.timestamp >= rangeStart && pose.timestamp <= rangeEnd
                }
                
                var lowestY: CGFloat = -.infinity
                var highestY: CGFloat = .infinity
                var lowestPose: PoseData?
                var highestPose: PoseData?
                
                for pose in posesInRange {
                    if let hipCenter = self.calculateHipCenter(from: pose) {
                        let hipY = hipCenter.y
                        
                        if hipY > lowestY {
                            lowestY = hipY
                            lowestPose = pose
                        }
                        
                        if hipY < highestY {
                            highestY = hipY
                            highestPose = pose
                        }
                    }
                }
                
                let impactPose: PoseData?
                let pelvisBasePose: PoseData?
                
                if let lowest = lowestPose, let highest = highestPose {
                    pelvisBasePose = lowest
                    impactPose = highest
                    print("📊 骨盤測定: 最低位置 y=\(String(format: "%.0f", lowestY)) → 最高位置 y=\(String(format: "%.0f", highestY))")
                } else {
                    pelvisBasePose = nil
                    impactPose = poseHistoryCopy.last
                    print("⚠️ 測定範囲内にポーズが見つかりませんでした")
                }
                
                if let base = pelvisBasePose, let impactPoseUnwrapped = impactPose {
                    if let details = MetricsCalculator.pelvisRiseDetails(base, impactPoseUnwrapped) {
                        if let hipTrophy = details.hipTrophy, let hipImpact = details.hipImpact {
                            print("📊 下半身貢献度:")
                            print("   最低位置: (x=\(String(format: "%.0f", hipTrophy.x)), y=\(String(format: "%.0f", hipTrophy.y)))")
                            print("   最高位置: (x=\(String(format: "%.0f", hipImpact.x)), y=\(String(format: "%.0f", hipImpact.y)))")
                            print("   上昇量: \(String(format: "%.1f", details.pixels)) px")
                        }
                    }
                }
                
                // 🔧 修正: フィルタリング済みのボールリストを使用
                let tossHistory = trophy.filteredBalls ?? []
                
                metrics = MetricsCalculator.calculateMetrics(
                    trophyPose: trophy,
                    impactEvent: impact,
                    tossHistory: tossHistory,  // ✅ フィルタリング済みを使用
                    imuHistory: self.watchIMUHistory,
                    calibration: nil,
                    baselineX: baselineX,
                    impactPose: impactPose,
                    pelvisBasePose: pelvisBasePose
                )
            } else {
                let frameCountCopy = self.dataQueue.sync { self.frameCount }
                let duration = Date().timeIntervalSince(self.measurementStartTime ?? Date())
                let avgFPS = Double(frameCountCopy) / max(1.0, duration)
                metrics = self.calculatePartialMetrics(avgFPS: avgFPS)
            }
            
            print("✅ 解析完了 - スコア: \(metrics.totalScore)/100")
            
            DispatchQueue.main.async {
                self.state = .completed(metrics)
            }
        }
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
            let poseHistoryCopy = dataQueue.sync { self.poseHistory }
            for pose in poseHistoryCopy {
                if let elbow = PoseDetector.calculateElbowAngle(from: pose, isRight: true) {
                    elbowAngles.append(elbow)
                }
            }
            elbowDeg = elbowAngles.isEmpty ? 165.0 : elbowAngles.reduce(0, +) / Double(elbowAngles.count)
            armpitDeg = 90.0
            leftTorso = 65.0
            leftExt = 170.0
        }
        
        let pelvisRise = 30.0
        let bodyAxisD = 10.0
        let rfYaw = 15.0
        let rfPitch = 10.0
        let wristDeg = 120.0

        let s1 = max(0, min(100, 100 - Int(abs(elbowDeg - 170) * 1.2)))
        let s2 = max(0, min(100, 100 - Int(abs(armpitDeg - 95) * 2.0)))
        let s3 = max(0, min(100, Int((pelvisRise / 60.0) * 100)))
        let s4a = max(0, min(100, 100 - Int(abs(leftTorso - 65) * 2.0)))
        let s4b = max(0, min(100, 100 - Int(abs(leftExt - 170) * 1.0)))
        let s4 = Int((Double(s4a) * 0.4) + (Double(s4b) * 0.6))
        let s5 = max(0, min(100, 100 - Int(max(0.0, bodyAxisD - 5.0) * 5.0)))
        let s6y = max(0, min(100, 100 - Int(max(0.0, abs(rfYaw) - 15.0) * 3.0)))
        let s6p = max(0, min(100, 100 - Int(max(0.0, abs(rfPitch) - 10.0) * 4.0)))
        let s6 = (s6y + s6p) / 2
        let s7 = max(0, min(100, 100 - Int(max(0.0, abs(0.0 - 0.4)) * 300.0)))
        let s8 = max(0, min(100, 100 - Int(max(0.0, abs(wristDeg - 170)) * 0.8)))

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
            tossOffsetFromBaselinePx: 0.0,
            wristRotationDeg: wristDeg,
            tossPositionX: 0.0,
            tossOffsetFromCenterPx: 0.0,
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
        autoStopTimer?.cancel()
        autoStopTimer = nil
        impactStopTimer?.cancel()
        impactStopTimer = nil
        
        videoCaptureManager?.stopPreview()
        videoCaptureManager?.stopRecording()
        videoCaptureManager = nil
        
        state = .idle
        
        dataQueue.async { [weak self] in
            guard let self = self else { return }
            self.frameCount = 0
            self.poseHistory.removeAll()
            self.watchIMUHistory.removeAll()
            self.trophyPoseEvent = nil
            self.impactEvent = nil
            self.measurementStartTime = nil
            self.frameDataHistory.removeAll()
            self.actualBallDetections = 0
            self.predictedBallDetections = 0
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.detectedPose = nil
            self?.detectedBall = nil
            self?.trophyPoseDetected = false
            self?.trophyAngles = nil
            self?.pelvisPosition = nil
        }
        
        // AIコンポーネントをクリア
        ballTrackerLock.lock()
        _ballTracker = nil
        ballTrackerLock.unlock()
        
        poseDetectorLock.lock()
        _poseDetector = nil
        poseDetectorLock.unlock()
        
        eventDetectorLock.lock()
        _eventDetector = nil
        eventDetectorLock.unlock()
        
        print("🧹 AI components cleared")
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
        dataQueue.async { [weak self] in
            guard let self = self else { return }
            self.watchIMUHistory.append(sample)
            
            let maxHistory = 2000
            if self.watchIMUHistory.count > maxHistory {
                self.watchIMUHistory.removeFirst(self.watchIMUHistory.count - maxHistory)
            }
        }
        
        let eventDet = getOrCreateEventDetector()
        eventDet.addIMUSample(sample)
    }
}

// MARK: - Video Capture Delegate
extension VideoAnalyzer: VideoCaptureDelegate {
    func videoCaptureDidOutput(sampleBuffer: CMSampleBuffer, timestamp: Double) {
        if case .recording = state {
            processFrame(sampleBuffer: sampleBuffer, timestamp: timestamp)
        }
        
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
