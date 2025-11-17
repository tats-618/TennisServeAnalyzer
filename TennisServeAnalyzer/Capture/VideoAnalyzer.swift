//
//  VideoAnalyzer.swift (⚡️ PERFORMANCE OPTIMIZED + FIXED INIT)
//  TennisServeAnalyzer
//
//  🎯 主要な最適化:
//  1. ✅ processFrame全体を非同期実行（メインスレッドブロック解消）
//  2. ✅ 重いAI処理をバックグラウンドスレッドで実行
//  3. ✅ UI更新のみをメインスレッドで実行
//  4. ✅ stopRecording時の重い処理を非同期化
//  5. ✅ finalizeAnalysisを非同期実行
//  6. 🆕 BallTracker/PoseDetectorの重複初期化を防止（スレッドセーフ）
//
//  🐛 修正した問題:
//  - BallTrackerが何度も初期化される問題（13回 → 1回）
//  - MLモデルの重複ロード（数秒の遅延）
//  - データ競合によるnilアクセス
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
    
    // 🆕 スレッドセーフな初期化
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
    
    // ⚡️ 非同期処理用のキュー
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
    private let poseDetectionInterval: Int = 5
    
    // MARK: - Initialization
    override init() {
        super.init()
        
        // Watch connectivity setup
        setupWatchConnectivity()
        
        // カメラ権限リクエスト
        requestCameraPermission()
        
        // 🆕 AI componentsを事前初期化（録画開始時に初めて作成）
        print("📱 VideoAnalyzer initialized (components will be lazy-loaded)")
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
    
    // MARK: - 🆕 Thread-Safe Lazy Initialization
    
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
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.trophyPoseDetected = false
            self?.trophyAngles = nil
            self?.pelvisPosition = nil
        }
        
        // 🆕 AI components を事前初期化（バックグラウンドで）
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
    
    // MARK: - ⚡️ Frame Processing (完全非同期化)
    private func processFrame(sampleBuffer: CMSampleBuffer, timestamp: Double) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.dataQueue.async {
                self.frameCount += 1
            }
            
            var currentPose: PoseData?
            var currentBall: BallDetection?
            
            // Pose detection
            let shouldDetectPose = self.dataQueue.sync { self.frameCount % self.poseDetectionInterval == 0 }
            
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
            
            // Ball detection (⚡️ 最適化: 3フレームに1回実行)
            let shouldDetectBall = self.dataQueue.sync { self.frameCount % 3 == 0 }
            
            if shouldDetectBall {
                let tracker = self.getOrCreateBallTracker()
                if let ball = tracker.trackBall(from: sampleBuffer, timestamp: timestamp) {
                    currentBall = ball
                    
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
    private func filterOutliers(from balls: [BallDetection]) -> [BallDetection] {
        guard balls.count > 2 else { return balls }
        
        let sortedBalls = balls.sorted { $0.timestamp < $1.timestamp }
        
        var filtered: [BallDetection] = []
        let screenWidth: CGFloat = 1280
        let screenHeight: CGFloat = 720
        
        for (index, ball) in sortedBalls.enumerated() {
            var shouldInclude = true
            
            if ball.position.x < 50 || ball.position.x > screenWidth - 50 {
                print("🚫 外れ値除外（画面端x）: t=\(String(format: "%.2f", ball.timestamp))s, x=\(Int(ball.position.x))")
                shouldInclude = false
            }
            
            if ball.position.y < 100 || ball.position.y > screenHeight - 100 {
                print("🚫 外れ値除外（画面端y）: t=\(String(format: "%.2f", ball.timestamp))s, y=\(Int(ball.position.y))")
                shouldInclude = false
            }
            
            if index > 0 && shouldInclude {
                let prevBall = sortedBalls[index - 1]
                let distance = sqrt(
                    pow(ball.position.x - prevBall.position.x, 2) +
                    pow(ball.position.y - prevBall.position.y, 2)
                )
                let timeDiff = ball.timestamp - prevBall.timestamp
                
                let maxDistancePerFrame: CGFloat = 100
                let maxDistance = maxDistancePerFrame * CGFloat(max(timeDiff / 0.016, 1.0))
                
                if distance > maxDistance {
                    print("🚫 外れ値除外（距離）: t=\(String(format: "%.2f", ball.timestamp))s, 距離=\(Int(distance))px")
                    shouldInclude = false
                }
            }
            
            if shouldInclude {
                filtered.append(ball)
            }
        }
        
        return filtered
    }
    
    // MARK: - Trophy Pose Detection from Ball Apex
    private func detectTrophyPoseFromBallApex() -> TrophyPoseEvent? {
        // 🆕 スレッドセーフにBallTrackerにアクセス
        let tracker = getOrCreateBallTracker()
        
        let ballHistory = tracker.getDetectionHistory()
        guard !ballHistory.isEmpty else {
            print("⚠️ ボール検出履歴がありません")
            return nil
        }
        
        print("📊 ボール検出数（フィルター前）: \(ballHistory.count)")
        
        let filteredBalls = filterOutliers(from: ballHistory)
        
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
        
        print("📊 ボール頂点: t=\(String(format: "%.2f", apex.timestamp))s, y=\(String(format: "%.0f", apex.position.y))")
        
        let poseHistoryCopy = dataQueue.sync { self.poseHistory }
        
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
            confidence: trophyPose.averageConfidence,
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
                
                print("🏆 トロフィーポーズ: t=\(String(format: "%.2f", trophy.timestamp))s, 右肘:\(elbowStr), 右脇:\(armpitStr), 左肩:\(leftShoulderStr), 左肘:\(leftElbowStr), ボール:(\(ballStr)), 骨盤:(\(pelvisStr))")
                
                let impact = self.impactEvent ?? self.createDummyImpactEvent()
                
                // 🆕 スレッドセーフにBallTrackerにアクセス
                let tracker = self.getOrCreateBallTracker()
                let tossHistory = tracker.getDetectionHistory()
                
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
                
                if let base = pelvisBasePose, let impact = impactPose {
                    if let details = MetricsCalculator.pelvisRiseDetails(base, impact) {
                        if let hipTrophy = details.hipTrophy, let hipImpact = details.hipImpact {
                            print("📊 下半身貢献度:")
                            print("   最低位置: (x=\(String(format: "%.0f", hipTrophy.x)), y=\(String(format: "%.0f", hipTrophy.y)))")
                            print("   最高位置: (x=\(String(format: "%.0f", hipImpact.x)), y=\(String(format: "%.0f", hipImpact.y)))")
                            print("   上昇量: \(String(format: "%.1f", details.pixels)) px")
                        }
                    }
                }
                
                metrics = MetricsCalculator.calculateMetrics(
                    trophyPose: trophy,
                    impactEvent: impact,
                    tossHistory: tossHistory,
                    imuHistory: self.watchIMUHistory,
                    calibration: nil,
                    courtCalibration: nil,
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
        let tossM = 0.30
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
        let s7 = max(0, min(100, 100 - Int(max(0.0, abs(tossM - 0.4)) * 300.0)))
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
            tossForwardDistanceM: tossM,
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
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.detectedPose = nil
            self?.detectedBall = nil
            self?.trophyPoseDetected = false
            self?.trophyAngles = nil
            self?.pelvisPosition = nil
        }
        
        // 🆕 AI componentsを明示的にクリア
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
