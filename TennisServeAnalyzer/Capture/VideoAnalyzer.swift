//
//  VideoAnalyzer.swift
//  TennisServeAnalyzer
//
//  Video analysis with Pose Detection + IMU Integration
//  🔧 修正: セッション管理機能を追加
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
    case sessionSummary([ServeMetrics])  // 🆕 セッション全体のまとめ
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
    
    // 🆕 セッション管理
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
    private var poseDetector: PoseDetector?
    private var eventDetector: EventDetector?
    private var ballTracker: BallTracker?
    
    // Session data
    private var frameCount: Int = 0
    private var poseHistory: [PoseData] = []
    private var trophyPoseEvent: TrophyPoseEvent?
    private var measurementStartTime: Date?  // 🆕 各測定の開始時刻
    
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
    // 🔧 修正: 最大撮影時間を60秒に延長（安全のためのセーフティタイマー）
    // 通常はユーザーが手動で「停止」ボタンを押すまで撮影を続ける
    // このタイマーは異常に長い撮影を防ぐためのフェイルセーフ
    private let maxSessionDuration: TimeInterval = 60.0
    private let poseDetectionInterval: Int = 5
    
    // MARK: - Initialization
    override init() {
        super.init()
        
        // Setup Watch connectivity
        setupWatchConnectivity()
        
        // 初期化時にカメラ権限をリクエスト
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
    
    // MARK: - 🆕 Session Management Methods
    
    /// 測定をリトライ（カメラセッティング画面に直接移動）
    func retryMeasurement() {
        print("🔄 Retrying measurement...")
        
        // 🔧 修正: タイマーをクリーンアップ
        autoStopTimer?.cancel()
        autoStopTimer = nil
        impactStopTimer?.cancel()
        impactStopTimer = nil
        
        // 現在の測定結果をセッションに保存
        if case .completed(let metrics) = state {
            sessionMetrics.append(metrics)
            print("✅ Added metrics to session (total: \(sessionMetrics.count))")
        }
        
        // カメラセッティング画面に直接移動
        state = .setupCamera
        prepareCameraPreview()
    }
    
    /// セッションを終了（まとめ画面に移動）
    func endSession() {
        print("🏁 Ending session...")
        
        // 🔧 修正: タイマーをクリーンアップ
        autoStopTimer?.cancel()
        autoStopTimer = nil
        impactStopTimer?.cancel()
        impactStopTimer = nil
        
        // 現在の測定結果を保存
        if case .completed(let metrics) = state {
            sessionMetrics.append(metrics)
            print("✅ Added final metrics to session")
        }
        
        // セッションまとめ画面に遷移
        guard !sessionMetrics.isEmpty else {
            print("⚠️ No metrics in session, returning to idle")
            state = .idle
            return
        }
        
        print("📊 Session summary with \(sessionMetrics.count) serves")
        state = .sessionSummary(sessionMetrics)
    }
    
    /// セッションを完全にリセット（ホームに戻る）
    func resetSession() {
        print("🔄 Resetting entire session...")
        sessionMetrics.removeAll()
        sessionStartDate = nil
        reset()  // 既存のresetメソッドを呼ぶ
    }
    
    // MARK: - Camera Setup Flow
    /// カメラセッティング画面に遷移（オーバーレイ表示）
    func setupCamera() {
        guard case .idle = state else { return }
        
        print("📷 Setting up camera with baseline overlay...")
        
        // 🆕 セッション開始日時を記録（最初のsetupCamera呼び出し時のみ）
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
        
        // 既存のマネージャーをクリーンアップ
        videoCaptureManager?.stopRecording()
        videoCaptureManager = nil
        
        // 新しいVideoCaptureManagerを作成
        let manager = VideoCaptureManager()
        manager.delegate = self
        videoCaptureManager = manager
        
        // プレビューレイヤーを準備
        _ = self.getPreviewLayer()
        
        // プレビューセッションを開始（録画なし）
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
        guard case .setupCamera = state else {
            print("⚠️ Cannot start recording from state: \(state)")
            return
        }
        
        print("🎬 Starting recording from camera setup...")
        startRecordingInternal()
    }
    
    private func startRecordingInternal() {
        // 既存のマネージャーをクリーンアップ
        videoCaptureManager?.stopRecording()
        videoCaptureManager = nil
        
        // Initialize video capture
        let manager = VideoCaptureManager()
        manager.delegate = self
        videoCaptureManager = manager
        
        // 既存のタイマーをキャンセル
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
        trophyPoseDetected = false
        trophyAngles = nil
        pelvisPosition = nil
        frameDataHistory.removeAll()
        
        // 🆕 測定開始時刻を記録（統計用）
        measurementStartTime = Date()
        
        // Start Watch recording
        watchManager?.startWatchRecording()
        
        // Start recording
        state = .recording
        videoCaptureManager?.startRecording()
        
        print("=== 測定開始 ===")
        
        // タイマーを保持して管理
        let timerWorkItem = DispatchWorkItem { [weak self] in
            print("⏰ 自動停止タイマー発火")
            self?.stopRecording()
        }
        autoStopTimer = timerWorkItem
        
        DispatchQueue.main.asyncAfter(deadline: .now() + maxSessionDuration, execute: timerWorkItem)
    }
    
    func stopRecording() {
        guard case .recording = state else { return }
        
        // タイマーをキャンセル
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
        
        var currentPose: PoseData?
        var currentBall: BallDetection?
        
        // Pose detection (every N frames)
        if frameCount % poseDetectionInterval == 0, let poseDet = getOrCreatePoseDetector() {
            if let pose = poseDet.detectPose(from: sampleBuffer, timestamp: timestamp) {
                poseHistory.append(pose)
                currentPose = pose
                
                DispatchQueue.main.async { [weak self] in
                    self?.detectedPose = pose
                }
            }
        }
        
        // Ball detection (every frame)
        if let tracker = getOrCreateBallTracker() {
            if let ball = tracker.trackBall(from: sampleBuffer, timestamp: timestamp) {
                currentBall = ball
                DispatchQueue.main.async { [weak self] in
                    self?.detectedBall = ball
                }
            }
            
            // 🔧 修正: トロフィーポーズ検出を削除
            // 測定終了後にボール軌跡から頂点を見つける
        }
        
        // 🆕 詳細ログ出力
        logFrameDetails(timestamp: timestamp, pose: currentPose, ball: currentBall)
    }
    
    // MARK: - 🆕 詳細ログ出力
    private func logFrameDetails(timestamp: Double, pose: PoseData?, ball: BallDetection?) {
        guard let pose = pose else { return }
        
        // 角度計算
        let rightElbow = PoseDetector.calculateElbowAngle(from: pose, isRight: true)
        let rightArmpit = PoseDetector.armpitAngle(pose, side: .right)
        let leftAngles = PoseDetector.leftHandAngles(pose)
        let leftShoulder = leftAngles?.torso
        let leftElbow = leftAngles?.extension
        
        // ボール位置
        let ballStr: String
        if let ball = ball {
            ballStr = String(format: "x=%.0f, y=%.0f", ball.position.x, ball.position.y)
        } else {
            ballStr = "x=---, y=---"
        }
        
        // 骨盤位置
        let pelvisStr: String
        if let pelvisPos = calculateHipCenter(from: pose) {
            pelvisStr = String(format: "x=%.0f, y=%.0f", pelvisPos.x, pelvisPos.y)
        } else {
            pelvisStr = "x=---, y=---"
        }
        
        // ログ出力
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
    
    // MARK: - 🆕 Outlier Filter for Ball Detection
    /// ボール検出から外れ値を除外するフィルター
    private func filterOutliers(from balls: [BallDetection]) -> [BallDetection] {
        guard balls.count > 2 else { return balls }
        
        // タイムスタンプでソート
        let sortedBalls = balls.sorted { $0.timestamp < $1.timestamp }
        
        var filtered: [BallDetection] = []
        let screenWidth: CGFloat = 1280
        let screenHeight: CGFloat = 720
        
        // 🆕 新しい設定
        let leftExclusionZone: CGFloat = screenWidth * 0.2  // 左20%除外
        let lowerHalfThreshold: CGFloat = screenHeight / 2  // 下半分除外
        let maxDistancePerFrame: CGFloat = 100              // 1フレームで100px以上 → 除外
        
        for (index, ball) in sortedBalls.enumerated() {
            var shouldInclude = true
            
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // 1. 画面の左20%を除外
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            if ball.position.x < leftExclusionZone {
                print("🚫 外れ値除外（左20%）: t=\(String(format: "%.2f", ball.timestamp))s, x=\(Int(ball.position.x)) (< \(Int(leftExclusionZone)))")
                shouldInclude = false
            }
            
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // 2. 画面の下半分を除外
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            if ball.position.y > lowerHalfThreshold {
                print("🚫 外れ値除外（下半分）: t=\(String(format: "%.2f", ball.timestamp))s, y=\(Int(ball.position.y)) (> \(Int(lowerHalfThreshold)))")
                shouldInclude = false
            }
            
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // 3. 前フレームとの距離チェック
            //    1フレームで100px以上移動 → 除外
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
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
    
    // MARK: - 🆕 Trophy Pose Detection from Ball Apex
    /// ボール軌跡から頂点（y座標最小）を見つけ、そのタイムスタンプのポーズをトロフィーポーズとする
    private func detectTrophyPoseFromBallApex() -> TrophyPoseEvent? {
        // ボール軌跡を取得
        guard let tracker = ballTracker else {
            print("⚠️ ボールトラッカーが存在しません")
            return nil
        }
        
        let ballHistory = tracker.getDetectionHistory()
        guard !ballHistory.isEmpty else {
            print("⚠️ ボール検出履歴がありません")
            return nil
        }
        
        print("📊 ボール検出数（フィルター前）: \(ballHistory.count)")
        
        // 🆕 外れ値を除外するフィルター
        let filteredBalls = filterOutliers(from: ballHistory)
        
        guard !filteredBalls.isEmpty else {
            print("⚠️ フィルター後にボール検出がありません")
            return nil
        }
        
        print("📊 ボール検出数（フィルター後）: \(filteredBalls.count)")
        
        // y座標が最小のボール（画面上で最も高い位置）を見つける
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
        
        // 頂点のタイムスタンプに最も近いポーズを見つける
        guard !poseHistory.isEmpty else {
            print("⚠️ ポーズ履歴がありません")
            return nil
        }
        
        var closestPose: PoseData?
        var minTimeDiff: Double = .infinity
        
        for pose in poseHistory {
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
        
        print("📊 トロフィーポーズ: t=\(String(format: "%.2f", trophyPose.timestamp))s (ボール頂点との時間差: \(String(format: "%.3f", minTimeDiff))s)")
        
        // 角度を計算
        let rightElbow = PoseDetector.calculateElbowAngle(from: trophyPose, isRight: true)
        let rightArmpit = PoseDetector.armpitAngle(trophyPose, side: .right)
        let leftAngles = PoseDetector.leftHandAngles(trophyPose)
        let leftShoulder = leftAngles?.torso
        let leftElbow = leftAngles?.extension
        
        // タプル型を明示的に定義（heightはCGFloat）
        let tossApexTuple: (time: Double, height: CGFloat)? = (time: apex.timestamp, height: apex.position.y)
        
        // TrophyPoseEventを生成
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
        guard let eventDet = getOrCreateEventDetector() else { return }
        guard impactEvent == nil else { return }
        
        let recentWindow = eventDet.getRecentIMU(duration: 2.0)
        
        if let impact = eventDet.detectImpact(in: recentWindow) {
            impactEvent = impact
            
            print("💥 Impact detected from IMU!")
            print("   - Peak Angular Velocity: \(String(format: "%.1f", impact.peakAngularVelocity)) rad/s")
            print("   - Confidence: \(String(format: "%.2f", impact.confidence))")
            
            // 🔧 修正: 自動停止タイマーを削除
            // IMU でインパクトを検出しても、ユーザーが手動で停止するまで撮影を続ける
        }
    }
    
    // MARK: - Analysis
    private func finalizeAnalysis() {
        print("=== 測定終了 ===")
        print("\n=== 最終解析開始 ===")
        
        let metrics: ServeMetrics
        
        // 🆕 ボール軌跡からトロフィーポーズを検出
        let trophyResult = detectTrophyPoseFromBallApex()
        
        if let trophy = trophyResult {
            // トロフィーポーズログ（1行フォーマット）
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
            if let pelvisPos = calculateHipCenter(from: trophy.pose) {
                pelvisStr = String(format: "x=%.0f, y=%.0f", pelvisPos.x, pelvisPos.y)
            } else {
                pelvisStr = "x=---, y=---"
            }
            
            print("🏆 トロフィーポーズ（ボール頂点）: t=\(String(format: "%.2f", trophy.timestamp))s, 右肘:\(elbowStr), 右脇:\(armpitStr), 左肩:\(leftShoulderStr), 左肘:\(leftElbowStr), ボール位置:(\(ballStr)), 骨盤位置:(\(pelvisStr))")
            
            let impact = impactEvent ?? createDummyImpactEvent()
            
            // ボール軌跡の取得（全履歴を使用）
            let tossHistory = ballTracker?.getDetectionHistory() ?? []
            
            // 下半身貢献度の測定
            // 🔧 変更: 測定区間をトロフィーポーズ-0.2s～+0.6s（合計0.8秒）に変更
            let windowBefore: Double = 0.2  // トロフィーポーズの0.2秒前
            let windowAfter: Double = 0.6   // トロフィーポーズの0.6秒後
            let rangeStart = trophy.timestamp - windowBefore
            let rangeEnd = trophy.timestamp + windowAfter
            
            print("📊 骨盤測定区間: t=\(String(format: "%.2f", rangeStart))s ～ \(String(format: "%.2f", rangeEnd))s (0.8秒間)")
            
            let posesInRange = poseHistory.filter { pose in
                pose.timestamp >= rangeStart && pose.timestamp <= rangeEnd
            }
            
            // 🔧 修正: 初期値を正しく設定
            var lowestY: CGFloat = -.infinity   // 最も下（y座標が大きい）を見つけるため最小値で初期化
            var highestY: CGFloat = .infinity   // 最も上（y座標が小さい）を見つけるため最大値で初期化
            var lowestPose: PoseData?
            var highestPose: PoseData?
            
            for pose in posesInRange {
                if let hipCenter = calculateHipCenter(from: pose) {
                    let hipY = hipCenter.y
                    
                    // 最低位置（y座標が最も大きい = 画面下）
                    if hipY > lowestY {
                        lowestY = hipY
                        lowestPose = pose
                    }
                    
                    // 最高位置（y座標が最も小さい = 画面上）
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
                impactPose = poseHistory.last
                print("⚠️ 測定範囲内にポーズが見つかりませんでした。最後のポーズを使用します。")
            }
            
            if let base = pelvisBasePose, let impact = impactPose {
                if let details = MetricsCalculator.pelvisRiseDetails(base, impact) {
                    if let hipTrophy = details.hipTrophy, let hipImpact = details.hipImpact {
                        print("📊 下半身貢献度（骨盤上昇量）:")
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
            let duration = Date().timeIntervalSince(Date())
            let avgFPS = Double(frameCount) / max(1.0, duration)
            metrics = calculatePartialMetrics(avgFPS: avgFPS)
        }
        
        print("✅ 解析完了 - スコア: \(metrics.totalScore)/100")
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
        // タイマーをクリーンアップ
        autoStopTimer?.cancel()
        autoStopTimer = nil
        impactStopTimer?.cancel()
        impactStopTimer = nil
        
        // プレビューを停止
        videoCaptureManager?.stopPreview()
        videoCaptureManager?.stopRecording()
        videoCaptureManager = nil
        
        state = .idle
        frameCount = 0
        poseHistory.removeAll()
        watchIMUHistory.removeAll()
        trophyPoseEvent = nil
        impactEvent = nil
        measurementStartTime = nil
        detectedPose = nil
        detectedBall = nil
        trophyPoseDetected = false
        trophyAngles = nil
        pelvisPosition = nil
        frameDataHistory.removeAll()
        ballTracker = nil
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
