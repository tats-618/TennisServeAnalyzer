//
//  VideoAnalyzer.swift (🧪 UI DISABLED DIAGNOSTIC MODE - 最新フレーム優先版)
//  TennisServeAnalyzer
//

import Foundation
import AVFoundation
import CoreMedia
import Combine

// MARK: - Analysis State
enum AnalysisState: Equatable {
    case idle
    case setupCamera
    case recording
    case analyzing
    case completed(ServeMetrics)
    case sessionSummary([ServeMetrics])
    case error(String)
    
    // ⚠️ Associated Value ありなので自前で Equatable を実装
    static func == (lhs: AnalysisState, rhs: AnalysisState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.setupCamera, .setupCamera),
             (.recording, .recording),
             (.analyzing, .analyzing),
             (.completed, .completed),
             (.sessionSummary, .sessionSummary),
             (.error, .error):
            return true
        default:
            return false
        }
    }
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
    
    // ★ 追加: Watchから受信したServeAnalysis
    private var watchAnalysis: ServeAnalysis?
    
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
        
        // ★ 追加: ServeAnalysis受信コールバック
        watchManager?.onAnalysisResultReceived = { [weak self] analysis in
            self?.handleWatchAnalysis(analysis)
        }
    }
    
    // MARK: - ★ Sensor Fusion Handler
    private func handleWatchAnalysis(_ analysis: ServeAnalysis) {
        let receiveTime = Date()
        print("📊 Received ServeAnalysis from Watch at \(receiveTime)")
        if let impactTime = analysis.impactTimestamp {
            print("   Impact timestamp: \(String(format: "%.6f", impactTime))s")
        }
        if let yaw = analysis.impactRacketYaw {
            print("   Racket yaw: \(String(format: "%.1f", yaw))°")
        }
        if let pitch = analysis.impactRacketPitch {
            print("   Racket pitch: \(String(format: "%.1f", pitch))°")
        }
        if let peakR = analysis.swingPeakPositionR {
            print("   Peak position (r): \(String(format: "%.3f", peakR))")
        } else {
            print("   ⚠️ Peak position (r) is nil")
        }
    
        self.watchAnalysis = analysis
        print("   ✅ watchAnalysis updated successfully")
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
        
        // ★ 重要: watchAnalysisを即座にリセット（前回のデータを確実にクリア）
        self.watchAnalysis = nil
        
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
            self.watchAnalysis = nil
            
            self.ballTrackerLock.lock()
            self._ballTracker = nil
            self.ballTrackerLock.unlock()
        }
        
        // 各コンポーネントのウォームアップ
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            _ = self.getOrCreatePoseDetector()
            _ = self.getOrCreateBallTracker()
            _ = self.getOrCreateEventDetector()
        }
        
        measurementStartTime = Date()
        
        // ★ NTP時刻同期を開始
        print("🕒 Starting NTP time sync...")
        
        watchManager?.startNTPSync { success in
            if success {
                let offset = SyncCoordinator.shared.timeOffset
                let rtt = SyncCoordinator.shared.syncQuality
                print("✅ NTP sync completed successfully")
                print("   Time offset: \(String(format: "%.3f", offset * 1000))ms")
                print("   RTT: \(String(format: "%.1f", rtt * 1000))ms")
            } else {
                print("⚠️ NTP sync failed, will use fallback method")
            }
        }

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
            
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
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
    
    // MARK: - ★ Sensor Fusion - Finalize Analysis
    private func finalizeAnalysis() {
        print("=== 測定終了（センサーフュージョン版・ロバスト対応） ===")
        processingQueue.async { [weak self] in
            guard let self = self else { return }
    
            var metrics: ServeMetrics
            let trophyResult = self.detectTrophyPoseFromBallApex()
    
            if let trophy = trophyResult {
                let frameWidth = trophy.pose.imageSize.width
                let baselineX = frameWidth / 2.0
    
                // ★ 修正1: Watchデータを必須とせず、取得できている場合のみ変数に保持
                let watchData = self.watchAnalysis
                if watchData == nil {
                    print("⚠️ Watch data missing or delayed. Proceeding with Vision-only analysis.")
                } else {
                    print("✅ Watch data available")
                    if let peakR = watchData?.swingPeakPositionR {
                        print("   Peak position (r) in watchData: \(String(format: "%.3f", peakR))")
                    } else {
                        print("   ⚠️ Peak position (r) is nil in watchData")
                    }
                }
    
                // ★ ステップ2: インパクトタイムスタンプをiOS基準に変換（Watchデータがある場合のみ）
                var impactTimeIOS: Double?
                var impactPose: PoseData?
                var syncQuality = "no_sync"
    
                if let wData = watchData,
                   let impactTimeWatch = wData.impactTimestamp,
                   SyncCoordinator.shared.isSyncComplete {
                    
                    // NTP同期が完了している場合
                    if let convertedTime = SyncCoordinator.shared.convertWatchTimeToiOS(impactTimeWatch) {
                        impactTimeIOS = convertedTime
                        syncQuality = "ntp_sync"
    
                        print("✅ Sensor Fusion:")
                        print("   Watch impact time: \(String(format: "%.6f", impactTimeWatch))s")
                        print("   iOS impact time: \(String(format: "%.6f", convertedTime))s")
    
                        // ★ ステップ3: poseHistoryから最近接フレームを検索
                        let poseHistoryCopy = self.dataQueue.sync { self.poseHistory }
                        impactPose = self.findClosestPose(to: convertedTime, in: poseHistoryCopy)
    
                        if let pose = impactPose {
                            let timeDiff = abs(pose.timestamp - convertedTime)
                            print("   Closest pose: \(String(format: "%.6f", pose.timestamp))s (diff: \(String(format: "%.3f", timeDiff * 1000))ms)")
                        }
                    }
                } else {
                    // Watchデータがない、または同期未完了の場合
                    if watchData == nil {
                        syncQuality = "vision_only"
                    } else {
                        print("⚠️ NTP sync not complete, skipping precise timestamp fusion")
                        syncQuality = "no_ntp_sync"
                    }
                }
    
                // フォールバック: インパクトPoseが特定できなかった場合、poseHistoryの最後（またはTrophyの少し後）を使用
                if impactPose == nil {
                    let poseHistoryCopy = self.dataQueue.sync { self.poseHistory }
                    
                    // ヒューリスティック: トロフィーポーズから約0.4秒後のフレームを探す
                    let estimatedImpactTime = trophy.timestamp + 0.4
                    impactPose = self.findClosestPose(to: estimatedImpactTime, in: poseHistoryCopy) ?? poseHistoryCopy.last
                    
                    syncQuality += "_fallback"
                    print("   Using fallback impact pose (approx 0.4s after trophy)")
                }
    
                // ★ ステップ4: 骨盤上昇量計算のためのベース/ピークPose取得
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
                let pelvisImpactPose = highestPose ?? impactPose
    
                // ★ ステップ5: 体軸の傾きを計算
                var bodyAxisDelta: Double = 999.0
                if let pose = impactPose {
                    bodyAxisDelta = PoseDetector.bodyAxisDelta(pose) ?? 999.0
                    print("✅ Body axis calculated: \(String(format: "%.1f", bodyAxisDelta))°")
                } else {
                    bodyAxisDelta = PoseDetector.bodyAxisDelta(trophy.pose) ?? 999.0
                }
    
                // ★ ステップ6: Watch データをダミーImpactEventに変換（ない場合は推定時刻）
                let dummyImpact = ImpactEvent(
                    timestamp: impactTimeIOS ?? (trophy.timestamp + 0.4),
                    monotonicMs: Int64((impactTimeIOS ?? (trophy.timestamp + 0.4)) * 1000),
                    peakAngularVelocity: 0.0,
                    peakJerk: 0.0,
                    spectralPower: 0.0,
                    confidence: 1.0
                )
    
                let tossHistory = trophy.filteredBalls ?? []
    
                // ★ ステップ7: メトリクス計算 (Watch IMUがない場合は空配列で計算される)
                let rawMetrics = MetricsCalculator.calculateMetrics(
                    trophyPose: trophy,
                    impactEvent: dummyImpact,
                    tossHistory: tossHistory,
                    imuHistory: self.watchIMUHistory,
                    calibration: nil,
                    baselineX: baselineX,
                    impactPose: pelvisImpactPose,
                    pelvisBasePose: pelvisBasePose
                )
    
                // ★ ステップ8: Watchの解析データがあれば上書き反映
                var finalYaw = rawMetrics.racketFaceYawDeg
                var finalPitch = rawMetrics.racketFacePitchDeg
                var finalScore5 = rawMetrics.score5_bodyAxisTilt
                var finalScore6 = rawMetrics.score6_racketFaceAngle
                var finalPeakTimingR = rawMetrics.wristRotationDeg  // ← 追加（ピーク加速タイミング）
                var finalScore8 = rawMetrics.score8_wristwork       // ← 追加
    
                if let wData = watchData,
                   let yaw = wData.impactRacketYaw,
                   let pitch = wData.impactRacketPitch {
                    print("✅ Using Watch racket angles: yaw=\(String(format: "%.1f", yaw))°, pitch=\(String(format: "%.1f", pitch))°")
                    finalYaw = yaw
                    finalPitch = pitch
                    finalScore6 = self.scoreRacketFace(yaw: yaw, pitch: pitch)
                }
    
                // 体軸スコアを再計算
                finalScore5 = self.scoreBodyAxisTilt(bodyAxisDelta)
    
                // ★ ピーク加速タイミングをWatchデータから取得（あれば上書き）
                if let wData = watchData, let peakR = wData.swingPeakPositionR {
                    print("✅ Using Watch peak acceleration timing: r=\(String(format: "%.3f", peakR))")
                    finalPeakTimingR = peakR
                    finalScore8 = self.scorePeakAccelerationTiming(peakR)
                } else {
                    print("⚠️ Using iOS calculated peak timing: r=\(String(format: "%.3f", finalPeakTimingR)) (score: \(finalScore8))")
                }
    
                // メトリクスを再構築
                var tempMetrics = ServeMetrics(
                    elbowAngleDeg: rawMetrics.elbowAngleDeg,
                    armpitAngleDeg: rawMetrics.armpitAngleDeg,
                    pelvisRisePx: rawMetrics.pelvisRisePx,
                    leftArmTorsoAngleDeg: rawMetrics.leftArmTorsoAngleDeg,
                    leftArmExtensionDeg: rawMetrics.leftArmExtensionDeg,
                    bodyAxisDeviationDeg: bodyAxisDelta,
                    racketFaceYawDeg: finalYaw,
                    racketFacePitchDeg: finalPitch,
                    tossOffsetFromBaselinePx: rawMetrics.tossOffsetFromBaselinePx,
                    wristRotationDeg: finalPeakTimingR,            // ← 変更（ピーク加速タイミング）
                    tossPositionX: rawMetrics.tossPositionX,
                    tossOffsetFromCenterPx: rawMetrics.tossOffsetFromCenterPx,
                    score1_elbowAngle: rawMetrics.score1_elbowAngle,
                    score2_armpitAngle: rawMetrics.score2_armpitAngle,
                    score3_lowerBodyContribution: rawMetrics.score3_lowerBodyContribution,
                    score4_leftHandPosition: rawMetrics.score4_leftHandPosition,
                    score5_bodyAxisTilt: finalScore5,
                    score6_racketFaceAngle: finalScore6,
                    score7_tossPosition: rawMetrics.score7_tossPosition,
                    score8_wristwork: finalScore8,                 // ← 変更（ピーク加速タイミングスコア）
                    totalScore: 0,
                    timestamp: Date(),
                    flags: rawMetrics.flags + ["robust_fusion", syncQuality]
                )
    
                // 総合スコアを再計算
                let scores = [
                    tempMetrics.score1_elbowAngle,
                    tempMetrics.score2_armpitAngle,
                    tempMetrics.score3_lowerBodyContribution,
                    tempMetrics.score4_leftHandPosition,
                    tempMetrics.score5_bodyAxisTilt,
                    tempMetrics.score6_racketFaceAngle,
                    tempMetrics.score7_tossPosition,
                    tempMetrics.score8_wristwork
                ]
                let total = Double(scores.reduce(0, +)) / 8.0
    
                metrics = ServeMetrics(
                    elbowAngleDeg: tempMetrics.elbowAngleDeg,
                    armpitAngleDeg: tempMetrics.armpitAngleDeg,
                    pelvisRisePx: tempMetrics.pelvisRisePx,
                    leftArmTorsoAngleDeg: tempMetrics.leftArmTorsoAngleDeg,
                    leftArmExtensionDeg: tempMetrics.leftArmExtensionDeg,
                    bodyAxisDeviationDeg: tempMetrics.bodyAxisDeviationDeg,
                    racketFaceYawDeg: tempMetrics.racketFaceYawDeg,
                    racketFacePitchDeg: tempMetrics.racketFacePitchDeg,
                    tossOffsetFromBaselinePx: tempMetrics.tossOffsetFromBaselinePx,
                    wristRotationDeg: tempMetrics.wristRotationDeg,
                    tossPositionX: tempMetrics.tossPositionX,
                    tossOffsetFromCenterPx: tempMetrics.tossOffsetFromCenterPx,
                    score1_elbowAngle: tempMetrics.score1_elbowAngle,
                    score2_armpitAngle: tempMetrics.score2_armpitAngle,
                    score3_lowerBodyContribution: tempMetrics.score3_lowerBodyContribution,
                    score4_leftHandPosition: tempMetrics.score4_leftHandPosition,
                    score5_bodyAxisTilt: tempMetrics.score5_bodyAxisTilt,
                    score6_racketFaceAngle: tempMetrics.score6_racketFaceAngle,
                    score7_tossPosition: tempMetrics.score7_tossPosition,
                    score8_wristwork: tempMetrics.score8_wristwork,
                    totalScore: Int(total),
                    timestamp: tempMetrics.timestamp,
                    flags: tempMetrics.flags
                )
    
            } else {
                // トロフィーポーズ検出失敗時のみフォールバック（50点）
                print("⚠️ Trophy pose detection failed.")
                let frameCountCopy = self.dataQueue.sync { self.processedFrameCount }
                let duration = Date().timeIntervalSince(self.measurementStartTime ?? Date())
                let avgFPS = Double(frameCountCopy) / max(1.0, duration)
                metrics = self.calculatePartialMetrics(avgFPS: avgFPS)
            }
    
            print("✅ 解析完了（スコア: \(metrics.totalScore)）")
            DispatchQueue.main.async {
                self.state = .completed(metrics)
            }
        }
    }
    
    // MARK: - ★ Sensor Fusion Helper Methods
    /// 最近接Poseを検索
    private func findClosestPose(to targetTime: Double, in poseHistory: [PoseData]) -> PoseData? {
        var closestPose: PoseData?
        var minTimeDiff = Double.infinity
    
        for pose in poseHistory {
            let timeDiff = abs(pose.timestamp - targetTime)
            if timeDiff < minTimeDiff {
                minTimeDiff = timeDiff
                closestPose = pose
            }
        }
    
        return closestPose
    }
    
    /// スコア計算ヘルパー（MetricsCalculatorから移植）
    private func scoreBodyAxisTilt(_ deltaDeg: Double) -> Int {
        if deltaDeg <= 15 {
            return 100
        } else if deltaDeg <= 60 {
            return Int(100.0 * (60.0 - deltaDeg) / 45.0)
        } else {
            return 0
        }
    }
    
    private func scoreRacketFace(yaw: Double, pitch: Double) -> Int {
        let sYaw: Int
        let absYaw = abs(yaw)
        if absYaw <= 5 {
            sYaw = 50
        } else if absYaw <= 60 {
            sYaw = Int(50.0 * (60.0 - absYaw) / 55.0)
        } else {
            sYaw = 0
        }
    
        let sPitch: Int
        let absPitch = abs(pitch)
        if absPitch <= 10 {
            sPitch = 50
        } else if absPitch <= 60 {
            sPitch = Int(50.0 * (50.0 - (absPitch - 10.0)) / 50.0)
        } else {
            sPitch = 0
        }
    
        return sYaw + sPitch
    }
    
    /// ピーク加速タイミングのスコアリング
    private func scorePeakAccelerationTiming(_ r: Double) -> Int {
        if r >= 0.9 {
            return 100
        } else if r > 0 {
            return Int((100.0 * r) / 0.9)
        } else {
            return 0
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
            wristRotationDeg: 0.5,
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
            self.watchAnalysis = nil
        }
        
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
        enqueueFrame(sampleBuffer: sampleBuffer)
    }
    
    func videoCaptureDidFail(error: Error) {
        DispatchQueue.main.async { [weak self] in self?.state = .error(error.localizedDescription) }
    }
    func videoCaptureDidStart() { print("✅ Video capture started") }
    func videoCaptureDidStop() { print("✅ Video capture stopped") }
}
