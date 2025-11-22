//
//  VideoAnalyzer.swift (🧪 UI DISABLED DIAGNOSTIC MODE - 最新フレーム優先版)
//  TennisServeAnalyzer
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
    
    // ⚠️ UI更新無効化: 以下のプロパティは更新されません
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
    private var processedFrameCount: Int = 0
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
    
    // MARK: - Processing Control
    
    /// 📌 重い後処理・集計用（録画終了後の finalizeAnalysis など）
    private let processingQueue = DispatchQueue(
        label: "com.tennisserve.processing",
        qos: .userInitiated
    )
    
    /// 📌 ライブ Vision 用：最新フレームだけ処理するシリアルキュー
    private let visionQueue = DispatchQueue(
        label: "com.tennisserve.vision",
        qos: .userInitiated
    )
    
    /// メタデータ用（カウンタ、履歴など）
    private let dataQueue = DispatchQueue(
        label: "com.tennisserve.data",
        qos: .userInitiated
    )
    
    /// 最新フレームバッファ（古いものは全部捨てる）
    private var latestSampleBuffer: CMSampleBuffer?
    
    /// Vision が現在フレーム処理中かどうか
    private var isProcessingLatest: Bool = false
    
    /// 全体の解析fps制御用（120fps入力 → 30fps解析など）
    private var lastAnalyzedTime: Double = 0.0
    private let analysisInterval: Double = 1.0 / 30.0   // 30fps 相当
    
    /// 個別の解析間引き（Pose / Ball 用、timestamp ベース）
    private var lastPoseAnalysisTime: Double = 0.0
    private var lastBallAnalysisTime: Double = 0.0
    
    // ターゲット間隔（Pose / Ball）
    private let targetPoseInterval: Double = 0.041  // ≒24fps
    private let targetBallInterval: Double = 0.033  // ≒30fps
    
    private let maxSessionDuration: TimeInterval = 60.0
    
    // パフォーマンス測定
    private var actualBallDetections: Int = 0
    private var predictedBallDetections: Int = 0
    
    // MARK: - Initialization
    override init() {
        super.init()
        setupWatchConnectivity()
        requestCameraPermission()
        print("📱 VideoAnalyzer initialized (UI DISABLED MODE, latest-frame priority)")
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
        autoStopTimer?.cancel()
        autoStopTimer = nil
        impactStopTimer?.cancel()
        impactStopTimer = nil
        
        if case .completed(let metrics) = state {
            sessionMetrics.append(metrics)
        }
        
        state = .setupCamera
        prepareCameraPreview()
    }
    
    func endSession() {
        autoStopTimer?.cancel()
        autoStopTimer = nil
        impactStopTimer?.cancel()
        impactStopTimer = nil
        
        if case .completed(let metrics) = state {
            sessionMetrics.append(metrics)
        }
        
        guard !sessionMetrics.isEmpty else {
            state = .idle
            return
        }
        state = .sessionSummary(sessionMetrics)
    }
    
    func resetSession() {
        sessionMetrics.removeAll()
        sessionStartDate = nil
        reset()
    }
    
    // MARK: - Camera Setup
    func setupCamera() {
        guard case .idle = state else { return }
        if sessionStartDate == nil {
            sessionStartDate = Date()
        }
        prepareCameraPreview()
        state = .setupCamera
    }
    
    // MARK: - Camera Preview
    func prepareCameraPreview() {
        videoCaptureManager?.stopRecording()
        videoCaptureManager = nil
        
        let manager = VideoCaptureManager()
        manager.delegate = self
        videoCaptureManager = manager
        
        _ = self.getPreviewLayer()
        manager.startPreview()
    }
    
    // MARK: - Thread-Safe Lazy Initialization
    private func getOrCreatePoseDetector() -> PoseDetector {
        poseDetectorLock.lock()
        defer { poseDetectorLock.unlock() }
        if _poseDetector == nil { _poseDetector = PoseDetector() }
        return _poseDetector!
    }
    
    private func getOrCreateEventDetector() -> EventDetector {
        eventDetectorLock.lock()
        defer { eventDetectorLock.unlock() }
        if _eventDetector == nil { _eventDetector = EventDetector() }
        return _eventDetector!
    }
    
    private func getOrCreateBallTracker() -> BallTracker {
        ballTrackerLock.lock()
        defer { ballTrackerLock.unlock() }
        if _ballTracker == nil { _ballTracker = BallTracker() }
        return _ballTracker!
    }
    
    // MARK: - Main Flow
    func startRecording() {
        guard case .setupCamera = state else { return }
        
        print("🎬 Starting recording (UI Updates DISABLED, latest-frame priority)...")
        
        videoCaptureManager?.stopRecording()
        videoCaptureManager = nil
        
        let manager = VideoCaptureManager()
        manager.delegate = self
        videoCaptureManager = manager
        
        autoStopTimer?.cancel()
        autoStopTimer = nil
        impactStopTimer?.cancel()
        impactStopTimer = nil
        
        // 最新フレーム処理状態のリセット
        latestSampleBuffer = nil
        isProcessingLatest = false
        lastAnalyzedTime = 0.0
        lastPoseAnalysisTime = 0.0
        lastBallAnalysisTime = 0.0
        
        dataQueue.async { [weak self] in
            guard let self = self else { return }
            self.processedFrameCount = 0
            self.poseHistory.removeAll()
            self.watchIMUHistory.removeAll()
            self.trophyPoseEvent = nil
            self.impactEvent = nil
            self.frameDataHistory.removeAll()
            self.actualBallDetections = 0
            self.predictedBallDetections = 0
            
            self.ballTrackerLock.lock()
            self._ballTracker = nil
            self.ballTrackerLock.unlock()
        }
        
        // ⚠️ UI更新無効化: ここでのステートリセットは最低限
        /*
        DispatchQueue.main.async { [weak self] in
            self?.trophyPoseDetected = false
            self?.trophyAngles = nil
            self?.pelvisPosition = nil
        }
        */
        
        // 各コンポーネントのウォームアップ
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            _ = self.getOrCreatePoseDetector()
            _ = self.getOrCreateBallTracker()
            _ = self.getOrCreateEventDetector()
        }
        
        measurementStartTime = Date()
        watchManager?.startWatchRecording()
        state = .recording
        videoCaptureManager?.startRecording()
        
        let timerWorkItem = DispatchWorkItem { [weak self] in
            self?.stopRecording()
        }
        autoStopTimer = timerWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + maxSessionDuration, execute: timerWorkItem)
    }
    
    func stopRecording() {
        guard case .recording = state else { return }
        print("🛑 Stop recording...")
        
        autoStopTimer?.cancel()
        autoStopTimer = nil
        
        dataQueue.async { [weak self] in
            guard let self = self else { return }
            let total = self.actualBallDetections + self.predictedBallDetections
            if total > 0 {
                let actualPercent = Double(self.actualBallDetections) / Double(total) * 100
                print("📊 Ball Detection Stats (UI Hidden):")
                print("   Actual detections: \(self.actualBallDetections) (\(String(format: "%.1f", actualPercent))%)")
                print("   Predicted: \(self.predictedBallDetections)")
                print("   Total: \(total)")
                print("   Processed Frames: \(self.processedFrameCount)")
            }
        }
        
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.watchManager?.stopWatchRecording()
            self.videoCaptureManager?.stopRecording()
            
            DispatchQueue.main.async {
                self.state = .analyzing
            }
            
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.finalizeAnalysis()
            }
        }
    }
    
    // MARK: - 最新フレーム優先キュー
    
    /// Capture から呼ばれる入口。120fps入力を 30fps解析に間引きしつつ、
    /// 「最新1枚だけ」を Vision に渡す。
    private func enqueueFrame(sampleBuffer: CMSampleBuffer) {
        // タイムスタンプ取得
        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = CMTimeGetSeconds(ts)
        
        // 全体解析間引き（120fps → 30fps）
        if lastAnalyzedTime != 0.0 {
            let dt = now - lastAnalyzedTime
            if dt < analysisInterval {
                return
            }
        }
        lastAnalyzedTime = now
        
        // 最新フレームとしてセット（古いものは上書きして捨てる）
        latestSampleBuffer = sampleBuffer
        
        // すでにVision処理が走っていれば、終わったあとに最新を拾わせる
        if isProcessingLatest {
            return
        }
        isProcessingLatest = true
        
        visionQueue.async { [weak self] in
            self?.drainLatestFrame()
        }
    }
    
    /// 最新フレームがなくなるまで処理し続けるループ
    private func drainLatestFrame() {
        while true {
            guard let buffer = latestSampleBuffer else {
                break
            }
            // 処理対象として取り出し
            latestSampleBuffer = nil
            
            let ts = CMSampleBufferGetPresentationTimeStamp(buffer)
            let timestamp = CMTimeGetSeconds(ts)
            
            // 実際の解析ロジック
            processFrame(sampleBuffer: buffer, timestamp: timestamp)
        }
        isProcessingLatest = false
    }
    
    // MARK: - Frame Processing (UI DISABLED)
    private func processFrame(sampleBuffer: CMSampleBuffer, timestamp: Double) {
        // Serial Queue内 (visionQueue 上で実行される前提)
        
        dataQueue.async { [weak self] in
            self?.processedFrameCount += 1
        }
        
        // 1. Pose Detection（時間ベース間引き）
        let timeSincePose = timestamp - lastPoseAnalysisTime
        let shouldDetectPose = (lastPoseAnalysisTime == 0.0) || (timeSincePose >= targetPoseInterval)
        
        if shouldDetectPose {
            let poseDet = getOrCreatePoseDetector()
            if let pose = poseDet.detectPose(from: sampleBuffer, timestamp: timestamp) {
                lastPoseAnalysisTime = timestamp
                dataQueue.async { [weak self] in
                    self?.poseHistory.append(pose)
                }
                // UI 更新なし
                // DispatchQueue.main.async { self.detectedPose = pose }
            }
        }
        
        // 2. Ball Detection（時間ベース間引き + 予測）
        let timeSinceBall = timestamp - lastBallAnalysisTime
        let shouldDetectBall = (lastBallAnalysisTime == 0.0) || (timeSinceBall >= targetBallInterval)
        
        let tracker = getOrCreateBallTracker()
        
        if shouldDetectBall {
            if let ball = tracker.trackBall(from: sampleBuffer, timestamp: timestamp) {
                lastBallAnalysisTime = timestamp
                dataQueue.async { [weak self] in
                    self?.actualBallDetections += 1
                }
                // DispatchQueue.main.async { self.detectedBall = ball }
            }
        } else {
            if let ball = tracker.predictBallPosition(timestamp: timestamp) {
                dataQueue.async { [weak self] in
                    self?.predictedBallDetections += 1
                }
                // DispatchQueue.main.async { self.detectedBall = ball }
            }
        }
        
        // ログ出力（動作確認用）
        if processedFrameCount % 30 == 0 {
            print("Processing frame \(processedFrameCount) at \(String(format: "%.3f", timestamp))")
        }
    }
    
    // MARK: - Utility
    
    private func calculateHipCenter(from pose: PoseData) -> CGPoint? {
        guard let leftHip = pose.joints[.leftHip],
              let rightHip = pose.joints[.rightHip] else { return nil }
        return CGPoint(x: (leftHip.x + rightHip.x) / 2, y: (leftHip.y + rightHip.y) / 2)
    }
    
    private func filterOutliers(from balls: [BallDetection], screenSize: CGSize) -> [BallDetection] {
        // ... (元のコードそのまま)
        guard balls.count > 2 else { return balls }
        let sortedBalls = balls.sorted { $0.timestamp < $1.timestamp }
        var filtered: [BallDetection] = []
        let screenWidth: CGFloat = screenSize.width
        let screenHeight: CGFloat = screenSize.height
        let leftExclusionZone: CGFloat = screenWidth * 0.2
        let lowerHalfThreshold: CGFloat = screenHeight / 2
        let maxDistancePerFrame: CGFloat = 100
        
        for (index, ball) in sortedBalls.enumerated() {
            var shouldInclude = true
            if ball.position.x < leftExclusionZone { shouldInclude = false }
            if ball.position.y > lowerHalfThreshold { shouldInclude = false }
            if index > 0 && shouldInclude {
                let prevBall = sortedBalls[index - 1]
                let distance = sqrt(pow(ball.position.x - prevBall.position.x, 2) + pow(ball.position.y - prevBall.position.y, 2))
                if distance > maxDistancePerFrame { shouldInclude = false }
            }
            if shouldInclude { filtered.append(ball) }
        }
        return filtered
    }
    
    private func detectTrophyPoseFromBallApex() -> TrophyPoseEvent? {
        // ... (元のコードと同じ)
        let tracker = getOrCreateBallTracker()
        let ballHistory = tracker.getDetectionHistory()
        guard !ballHistory.isEmpty else { return nil }
        let poseHistoryCopy = dataQueue.sync { self.poseHistory }
        guard let firstPose = poseHistoryCopy.first else { return nil }
        let screenSize = CGSize(width: firstPose.imageSize.width, height: firstPose.imageSize.height)
        let filteredBalls = filterOutliers(from: ballHistory, screenSize: screenSize)
        guard !filteredBalls.isEmpty else { return nil }
        var apexBall: BallDetection?
        var minY: CGFloat = .infinity
        for ball in filteredBalls {
            if ball.position.y < minY {
                minY = ball.position.y
                apexBall = ball
            }
        }
        guard let apex = apexBall else { return nil }
        guard !poseHistoryCopy.isEmpty else { return nil }
        var closestPose: PoseData?
        var minTimeDiff: Double = .infinity
        for pose in poseHistoryCopy {
            let timeDiff = abs(pose.timestamp - apex.timestamp)
            if timeDiff < minTimeDiff {
                minTimeDiff = timeDiff
                closestPose = pose
            }
        }
        guard let trophyPose = closestPose else { return nil }
        let rightElbow = PoseDetector.calculateElbowAngle(from: trophyPose, isRight: true)
        let rightArmpit = PoseDetector.armpitAngle(trophyPose, side: .right)
        let leftAngles = PoseDetector.leftHandAngles(trophyPose)
        let leftShoulder = leftAngles?.torso
        let leftElbow = leftAngles?.extension
        let tossApexTuple: (time: Double, height: CGFloat)? = (time: apex.timestamp, height: apex.position.y)
        return TrophyPoseEvent(
            timestamp: trophyPose.timestamp,
            pose: trophyPose,
            tossApex: tossApexTuple,
            tossApexX: apex.position.x,
            filteredBalls: filteredBalls,
            confidence: trophyPose.averageConfidence,
            elbowAngle: rightElbow,
            shoulderAbduction: nil,
            isValid: true,
            rightElbowAngle: rightElbow,
            rightArmpitAngle: rightArmpit,
            leftShoulderAngle: leftShoulder,
            leftElbowAngle: leftElbow
        )
    }
    
    private func detectImpactFromIMU() {
        let eventDet = getOrCreateEventDetector()
        guard impactEvent == nil else { return }
        let recentWindow = eventDet.getRecentIMU(duration: 2.0)
        if let impact = eventDet.detectImpact(in: recentWindow) {
            impactEvent = impact
        }
    }
    
    private func finalizeAnalysis() {
        print("=== 測定終了 ===")
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            let metrics: ServeMetrics
            let trophyResult = self.detectTrophyPoseFromBallApex()
            
            if let trophy = trophyResult {
                let frameWidth = trophy.pose.imageSize.width
                let baselineX = frameWidth / 2.0
                let impact = self.impactEvent ?? self.createDummyImpactEvent()
                let windowBefore: Double = 0.2
                let windowAfter: Double = 0.6
                let rangeStart = trophy.timestamp - windowBefore
                let rangeEnd = trophy.timestamp + windowAfter
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
                        if hipY > lowestY { lowestY = hipY; lowestPose = pose }
                        if hipY < highestY { highestY = hipY; highestPose = pose }
                    }
                }
                let pelvisBasePose = lowestPose
                let impactPose = highestPose ?? poseHistoryCopy.last
                let tossHistory = trophy.filteredBalls ?? []
                
                metrics = MetricsCalculator.calculateMetrics(
                    trophyPose: trophy,
                    impactEvent: impact,
                    tossHistory: tossHistory,
                    imuHistory: self.watchIMUHistory,
                    calibration: nil,
                    baselineX: baselineX,
                    impactPose: impactPose,
                    pelvisBasePose: pelvisBasePose
                )
            } else {
                let frameCountCopy = self.dataQueue.sync { self.processedFrameCount }
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
        return ServeMetrics(
            elbowAngleDeg: 165.0,
            armpitAngleDeg: 90.0,
            pelvisRisePx: 30.0,
            leftArmTorsoAngleDeg: 65.0,
            leftArmExtensionDeg: 170.0,
            bodyAxisDeviationDeg: 10.0,
            racketFaceYawDeg: 15.0,
            racketFacePitchDeg: 10.0,
            tossOffsetFromBaselinePx: 0.0,
            wristRotationDeg: 120.0,
            tossPositionX: 0.0,
            tossOffsetFromCenterPx: 0.0,
            score1_elbowAngle: 50,
            score2_armpitAngle: 50,
            score3_lowerBodyContribution: 50,
            score4_leftHandPosition: 50,
            score5_bodyAxisTilt: 50,
            score6_racketFaceAngle: 50,
            score7_tossPosition: 50,
            score8_wristwork: 50,
            totalScore: 50,
            timestamp: Date(),
            flags: ["partial_metrics", "fps:\(Int(avgFPS))"]
        )
    }
    
    private func createDummyImpactEvent() -> ImpactEvent {
        let dummyTimestamp = (trophyPoseEvent?.timestamp ?? 0) + 0.5
        return ImpactEvent(timestamp: dummyTimestamp, monotonicMs: Int64(dummyTimestamp * 1000), peakAngularVelocity: 0.0, peakJerk: 0.0, spectralPower: 0.0, confidence: 0.0)
    }
    
    func reset() {
        autoStopTimer?.cancel()
        autoStopTimer = nil
        videoCaptureManager?.stopPreview()
        videoCaptureManager?.stopRecording()
        videoCaptureManager = nil
        state = .idle
        
        latestSampleBuffer = nil
        isProcessingLatest = false
        lastAnalyzedTime = 0.0
        lastPoseAnalysisTime = 0.0
        lastBallAnalysisTime = 0.0
        
        dataQueue.async { [weak self] in
            guard let self = self else { return }
            self.processedFrameCount = 0
            self.poseHistory.removeAll()
            self.watchIMUHistory.removeAll()
            self.trophyPoseEvent = nil
            self.impactEvent = nil
            self.measurementStartTime = nil
            self.frameDataHistory.removeAll()
            self.actualBallDetections = 0
            self.predictedBallDetections = 0
        }
        
        // ⚠️ UI更新無効化: ここでのリセットも最小限
        /*
        DispatchQueue.main.async { [weak self] in
            self?.detectedPose = nil
            self?.detectedBall = nil
            self?.trophyPoseDetected = false
            self?.trophyAngles = nil
            self?.pelvisPosition = nil
        }
        */
        
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
        if case .completed(let metrics) = state { return metrics }
        return nil
    }
    
    private func addIMUSample(_ sample: ServeSample) {
        dataQueue.async { [weak self] in
            guard let self = self else { return }
            self.watchIMUHistory.append(sample)
            if self.watchIMUHistory.count > 2000 {
                self.watchIMUHistory.removeFirst(self.watchIMUHistory.count - 2000)
            }
        }
        let eventDet = getOrCreateEventDetector()
        eventDet.addIMUSample(sample)
    }
    
    // MARK: - Watch Handlers
    private func handleWatchIMUSample(_ sample: ServeSample) { addIMUSample(sample) }
    private func handleWatchBatchData(_ samples: [ServeSample]) { samples.forEach { addIMUSample($0) }; detectImpactFromIMU() }
}

// MARK: - Video Capture Delegate
extension VideoAnalyzer: VideoCaptureDelegate {
    func videoCaptureDidOutput(sampleBuffer: CMSampleBuffer, timestamp: Double) {
        guard case .recording = state else { return }
        
        // 📌 ここでは一切重い処理をしない。
        //    ただ latestSampleBuffer に積んで visionQueue に投げるだけ。
        enqueueFrame(sampleBuffer: sampleBuffer)
        
        // FPS更新は依然としてUI負荷なので無効化
        /*
        if let manager = videoCaptureManager {
            DispatchQueue.main.async { [weak self] in
                self?.currentFPS = manager.currentFPS
            }
        }
        */
    }
    
    func videoCaptureDidFail(error: Error) {
        DispatchQueue.main.async { [weak self] in self?.state = .error(error.localizedDescription) }
    }
    func videoCaptureDidStart() { print("✅ Video capture started") }
    func videoCaptureDidStop() { print("✅ Video capture stopped") }
}

