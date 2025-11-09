//
//  VideoAnalyzer.swift
//  TennisServeAnalyzer
//
//  Video analysis with Pose Detection + IMU Integration
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
    
    // Watch IMU
    private var watchIMUHistory: [ServeSample] = []
    private var impactEvent: ImpactEvent?
    
    // Configuration
    private let maxSessionDuration: TimeInterval = 10.0
    private let poseDetectionInterval: Int = 6  // Every 8 frames (15fps detection at 120fps)
    
    // MARK: - Initialization
    override init() {
        super.init()
        print("📱 VideoAnalyzer init (with pose detection)")
        
        // Setup Watch connectivity
        setupWatchConnectivity()
    }
    
    // MARK: - Watch Connectivity Setup
    private func setupWatchConnectivity() {
        print("📡 Setting up Watch connectivity...")
        
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
        
        print("✅ Watch connectivity setup complete")
    }
    
    // MARK: - Watch Data Handlers
    private func handleWatchIMUSample(_ sample: ServeSample) {
        addIMUSample(sample)
    }
    
    private func handleWatchBatchData(_ samples: [ServeSample]) {
        print("📦 Processing Watch batch: \(samples.count) samples")
        
        for sample in samples {
            addIMUSample(sample)
        }
        
        // 🔧 NEW: Try to detect impact after receiving batch
        detectImpactFromIMU()
    }
    
    // MARK: - Lazy Initialization
    private func getOrCreatePoseDetector() -> PoseDetector? {
        if poseDetector == nil {
            print("🏃 Initializing PoseDetector...")
            poseDetector = PoseDetector()
            print("✅ PoseDetector initialized")
        }
        return poseDetector
    }
    
    private func getOrCreateEventDetector() -> EventDetector? {
        if eventDetector == nil {
            print("🎯 Initializing EventDetector...")
            eventDetector = EventDetector()
            print("✅ EventDetector initialized")
        }
        return eventDetector
    }
    
    private func getOrCreateBallTracker() -> BallTracker? {
        if ballTracker == nil {
            print("🎾 Initializing BallTracker (YOLO)...")
            ballTracker = BallTracker()
            print("✅ BallTracker initialized")
        }
        return ballTracker
    }
    
    // MARK: - Main Flow
    func startSession() {
        print("🎬 startSession called")
        
        guard case .idle = state else {
            print("⚠️ Not idle, current state: \(state)")
            return
        }
        
        print("📹 Requesting camera permission...")
        
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            print("🔐 Permission result: \(granted)")
            
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if granted {
                    print("✅ Permission granted, starting recording")
                    self.startRecording()
                } else {
                    print("❌ Permission denied")
                    self.state = .error("カメラ権限が必要です")
                }
            }
        }
    }
    
    private func startRecording() {
        print("🎥 startRecording called")
        
        // Initialize video capture if needed
        if videoCaptureManager == nil {
            print("📹 Creating VideoCaptureManager...")
            let manager = VideoCaptureManager()
            manager.delegate = self
            videoCaptureManager = manager
            print("✅ VideoCaptureManager created")
        }
        
        // Reset
        frameCount = 0
        poseHistory.removeAll()
        watchIMUHistory.removeAll()
        trophyPoseEvent = nil
        impactEvent = nil
        sessionStartTime = Date()
        trophyPoseDetected = false
        
        // Start Watch recording
        print("⌚ Starting Watch recording...")
        watchManager?.startWatchRecording()
        
        // Start
        print("▶️ Setting state to recording")
        state = .recording
        
        print("▶️ Starting capture")
        videoCaptureManager?.startRecording()
        
        print("✅ Recording started")
        
        // Auto-stop
        DispatchQueue.main.asyncAfter(deadline: .now() + maxSessionDuration) { [weak self] in
            print("⏱ Auto-stop triggered")
            self?.stopRecording()
        }
    }
    
    func stopRecording() {
        print("⏹ stopRecording called")
        
        guard case .recording = state else {
            print("⚠️ Not recording, state: \(state)")
            return
        }
        
        // Stop Watch recording
        print("⌚ Stopping Watch recording...")
        watchManager?.stopWatchRecording()
        
        videoCaptureManager?.stopRecording()
        
        print("🔍 Setting state to analyzing")
        state = .analyzing
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            print("📊 Performing analysis")
            self?.performAnalysis()
        }
    }
    
    // MARK: - Frame Processing
    private func processFrame(sampleBuffer: CMSampleBuffer, timestamp: Double) {
        guard case .recording = state else { return }
        
        frameCount += 1
        
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
                        
                        // Check for trophy pose
                        if trophyPoseEvent == nil {
                            if let eventDet = getOrCreateEventDetector(),
                               let trophy = eventDet.detectTrophyPose(pose: pose, ballApex: nil) {
                                trophyPoseEvent = trophy
                                print("✅ Trophy pose detected at t=\(String(format: "%.3f", trophy.timestamp))s")
                                
                                DispatchQueue.main.async { [weak self] in
                                    self?.trophyPoseDetected = true
                                }
                            }
                        } else {
                            DispatchQueue.main.async { [weak self] in
                                self?.trophyPoseDetected = true
                            }
                        }
                    }
                }
            }
        }
        
        // Ball detection
        if let tracker = getOrCreateBallTracker() {
            if let ball = tracker.trackBall(from: sampleBuffer, timestamp: timestamp) {
                DispatchQueue.main.async { [weak self] in
                    self?.detectedBall = ball
                }
                
                // Check for toss apex
                if let apex = tracker.detectTossApex() {
                    print("🎾 Toss apex detected at \(String(format: "%.3f", apex.timestamp))s")
                    
                    // Update trophy pose with apex info
                    if trophyPoseEvent == nil, let eventDet = getOrCreateEventDetector() {
                        let nearbyPoses = poseHistory.filter { pose in
                            abs(pose.timestamp - apex.timestamp) < 0.1
                        }
                        
                        if let nearestPose = nearbyPoses.min(by: { abs($0.timestamp - apex.timestamp) < abs($1.timestamp - apex.timestamp) }) {
                            if let trophy = eventDet.detectTrophyPose(
                                pose: nearestPose,
                                ballApex: (time: apex.timestamp, height: apex.height)
                            ) {
                                trophyPoseEvent = trophy
                                print("✅ Trophy pose detected with apex at t=\(String(format: "%.3f", trophy.timestamp))s")
                                
                                DispatchQueue.main.async { [weak self] in
                                    self?.trophyPoseDetected = true
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Log every second
        if frameCount % 120 == 0 {
            print("📸 Frame: \(frameCount), Poses: \(poseHistory.count)")
            
            if let tracker = ballTracker {
                let perf = tracker.getPerformanceInfo()
                print("🎾 Ball detection: \(String(format: "%.1f", perf.fps)) fps (avg: \(String(format: "%.1f", perf.avgMs))ms)")
            }
        }
        
        // 🔧 NEW: Check for impact periodically
        detectImpactFromIMU()
    }
    
    // MARK: - 🔧 NEW: Impact Detection from IMU
    private func detectImpactFromIMU() {
        guard impactEvent == nil else { return }
        guard watchIMUHistory.count >= 50 else { return }
        
        if let eventDet = getOrCreateEventDetector() {
            let recentIMU = Array(watchIMUHistory.suffix(100))
            
            if let impact = eventDet.detectImpact(in: recentIMU) {
                impactEvent = impact
                print("💥 Impact detected!")
                print("   - Time: \(String(format: "%.3f", impact.timestamp))s")
                print("   - Peak ω: \(String(format: "%.1f", impact.peakAngularVelocity)) rad/s")
                print("   - Peak jerk: \(String(format: "%.1f", impact.peakJerk)) m/s³")
                print("   - Confidence: \(Int(impact.confidence * 100))%")
                
                // Stop recording shortly after impact
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.stopRecording()
                }
            }
        }
    }
    
    // MARK: - Analysis
    private func performAnalysis() {
        print("🔍 Performing analysis...")
        print("   - Total frames: \(frameCount)")
        print("   - Pose frames: \(poseHistory.count)")
        print("   - IMU samples: \(watchIMUHistory.count)")
        print("   - Trophy pose: \(trophyPoseEvent != nil ? "✓" : "✗")")
        print("   - Impact: \(impactEvent != nil ? "✓" : "✗")")
        
        let duration = sessionStartTime.map { -$0.timeIntervalSinceNow } ?? maxSessionDuration
        let avgFPS = Double(frameCount) / duration
        
        guard poseHistory.count >= 3 else {
            print("❌ Not enough pose data")
            state = .error("骨格データが不足しています")
            return
        }
        
        // 🔧 NEW: Calculate metrics using MetricsCalculator if we have all data
        let metrics: ServeMetrics
        
        if let trophy = trophyPoseEvent, let impact = impactEvent {
            print("✅ Calculating full metrics with MetricsCalculator")
            
            let tossHistory = ballTracker?.getDetectionHistory() ?? []
            
            // 明示的にローカル変数へ分けて型推論を楽にする
            let trophyEvent: TrophyPoseEvent = trophy
            let impactEvt: ImpactEvent = impact
            let tossDetections: [BallDetection] = ballTracker?.getDetectionHistory() ?? []
            let imuAll: [ServeSample] = watchIMUHistory
            let calib: CalibrationResult? = nil
            let courtCalib: CourtCalibration? = nil
            let impactPose: PoseData? = nil   // 取れるなら近傍Poseを入れてOK

            metrics = MetricsCalculator.calculateMetrics(
                trophyPose: trophyEvent,
                impactEvent: impactEvt,
                tossHistory: tossDetections,
                imuHistory: imuAll,
                calibration: calib,
                courtCalibration: courtCalib,
                impactPose: impactPose
            )

        } else {
            print("⚠️ Using partial metrics (missing events)")
            metrics = calculatePartialMetrics(avgFPS: avgFPS)
        }
        
        print("✅ Analysis complete - Score: \(metrics.totalScore)/100")
        state = .completed(metrics)
    }
    
    private func calculatePartialMetrics(avgFPS: Double) -> ServeMetrics {
        // Poseから取りやすい肘/膝だけざっくり平均、他は暫定値＋低スコア
        var kneeFlexions: [Double] = []
        var elbowAngles: [Double] = []
        for pose in poseHistory {
            if let knee = PoseDetector.calculateKneeAngle(from: pose, isRight: true) {
                kneeFlexions.append(knee)
            }
            if let elbow = PoseDetector.calculateElbowAngle(from: pose, isRight: true) {
                elbowAngles.append(elbow)
            }
        }
        let avgKnee = kneeFlexions.isEmpty ? 140.0 : kneeFlexions.reduce(0, +) / Double(kneeFlexions.count)
        let avgElbow = elbowAngles.isEmpty ? 165.0 : elbowAngles.reduce(0, +) / Double(elbowAngles.count)

        // 暫定の生値（UIが落ちないように妥当域に）
        let elbowDeg = avgElbow
        let armpitDeg = 90.0
        let pelvisRise = 0.10
        let leftTorso = 65.0
        let leftExt   = 170.0
        let bodyAxisD = 10.0
        let rfYaw = 15.0
        let rfPitch = 10.0
        let tossM = 0.30
        let wristDeg = 120.0

        // スコアは MetricsCalculator のロジックに合わせたいが、ここは簡易に仮評価
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

        // 重み付け（MetricsCalculator と同じ配分）
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

    
    // MARK: - Utility
    func reset() {
        print("🔄 Reset called")
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
        ballTracker = nil
    }
    
    func getPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        print("🖼 getPreviewLayer called")
        
        if videoCaptureManager == nil {
            print("📹 Creating VideoCaptureManager for preview")
            let manager = VideoCaptureManager()
            manager.delegate = self
            videoCaptureManager = manager
        }
        
        let layer = videoCaptureManager?.createPreviewLayer()
        print(layer != nil ? "✅ Preview layer created" : "❌ No preview layer")
        return layer
    }
    
    func getCurrentMetrics() -> ServeMetrics? {
        if case .completed(let metrics) = state {
            return metrics
        }
        return nil
    }
    
    func addIMUSample(_ sample: ServeSample) {
        watchIMUHistory.append(sample)
        
        // 🔧 NEW: Pass to EventDetector
        if let eventDet = getOrCreateEventDetector() {
            eventDet.addIMUSample(sample)
        }
        
        // Keep bounded
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
        print("❌ Capture failed: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            self?.state = .error(error.localizedDescription)
        }
    }
    
    func videoCaptureDidStart() {
        print("✅ Capture started")
    }
    
    func videoCaptureDidStop() {
        print("✅ Capture stopped")
    }
}
