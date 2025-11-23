//
//  ContentView.swift
//  TennisServeAnalyzer
//
//  Main view with camera setup flow
//  🔧 修正: セッション管理に対応
//  🆕 NTP時刻同期を画面表示時に先行実行
//

import SwiftUI
import AVFoundation
import WatchConnectivity

struct ContentView: View {
    @StateObject private var videoAnalyzer = VideoAnalyzer()
    
    // 🆕 Watch接続マネージャーへの参照
    private let watchManager = WatchConnectivityManager.shared
    private let syncCoordinator = SyncCoordinator.shared
    
    var body: some View {
        ZStack {
            // Background
            Color.black.edgesIgnoringSafeArea(.all)
            
            // Main content based on state
            switch videoAnalyzer.state {
            case .idle:
                idleView
                
            case .setupCamera:
                cameraSetupView
                
            case .recording:
                recordingView
                
            case .analyzing:
                analyzingView
                
            case .completed(let metrics):
                AnalysisResultsView(
                    metrics: metrics,
                    onRetry: {
                        // 🔧 変更: setupCameraに直接移動
                        videoAnalyzer.retryMeasurement()
                    },
                    onEndSession: {
                        // 🆕 新規: セッション終了
                        videoAnalyzer.endSession()
                    }
                )
                
            case .sessionSummary(let allMetrics):
                // 🆕 新規: セッションまとめ画面
                SessionSummaryView(
                    serves: allMetrics,
                    onNewSession: {
                        videoAnalyzer.resetSession()
                    }
                )
                
            case .error(let message):
                errorView(message: message)
            }
        }
        .onAppear {
            print("📱 ContentView appeared")
            
            // 🆕 Watch接続時に先行してNTP同期を実行
            if WCSession.default.isReachable {
                print("⏳ Pre-syncing NTP with Watch...")
                
                syncCoordinator.performNTPSync(
                    sendMessageHandler: { request, completion in
                        watchManager.sendNTPSyncRequest(request, completion: completion)
                    },
                    completion: { success in
                        if success {
                            print("✅ Pre-sync complete")
                            print("   Offset: \(String(format: "%.3f", syncCoordinator.timeOffset * 1000))ms")
                            print("   Quality: \(String(format: "%.1f", syncCoordinator.syncQuality * 1000))ms RTT")
                        } else {
                            print("⚠️ Pre-sync failed, will retry during recording")
                        }
                    }
                )
            } else {
                print("⚠️ Watch not reachable, skipping pre-sync")
            }
        }
    }
    
    // MARK: - Idle View (アプリ起動直後)
    private var idleView: some View {
        VStack {
            Spacer()
            
            // タイトルとアイコン
            VStack(spacing: 24) {
                Image(systemName: "tennis.racket")
                    .font(.system(size: 80))
                    .foregroundColor(.green)
                    .shadow(color: .black, radius: 8, x: 0, y: 4)
                
                VStack(spacing: 16) {
                    Text("Tennis Serve Analyzer")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .shadow(color: .black, radius: 4, x: 0, y: 2)
                    
                    Text("サーブフォームを解析します")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.9))
                        .shadow(color: .black, radius: 4, x: 0, y: 2)
                }
            }
            .padding(.vertical, 30)
            .padding(.horizontal, 40)
            .background(
                RoundedRectangle(cornerRadius: 25)
                    .fill(Color.black.opacity(0.6))
                    .shadow(color: .black.opacity(0.4), radius: 12)
            )
            
            Spacer()
            
            // カメラセッティングボタン
            Button(action: {
                print("📷 User tapped Camera Setup")
                videoAnalyzer.setupCamera()
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "camera.viewfinder")
                        .font(.title2)
                    Text("カメラセッティング")
                        .fontWeight(.semibold)
                        .font(.title2)
                }
                .foregroundColor(.white)
                .frame(width: 280, height: 70)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.blue, Color.blue.opacity(0.8)]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(35)
                .shadow(color: .blue.opacity(0.5), radius: 10, x: 0, y: 5)
            }
            .padding(.bottom, 120)
        }
    }
    
    // MARK: - Camera Setup View (カメラ設置画面)
    private var cameraSetupView: some View {
        GeometryReader { geometry in
            ZStack {
                // カメラプレビュー
                CameraPreviewView(videoAnalyzer: videoAnalyzer)
                    .edgesIgnoringSafeArea(.all)
                
                // ベースラインオーバーレイ（赤い縦線）
                BaselineOverlayView(viewSize: geometry.size)
                
                // 下部コントロール
                VStack {
                    Spacer()
                    
                    HStack(spacing: 20) {
                        // キャンセルボタン
                        Button(action: {
                            print("❌ User cancelled camera setup")
                            videoAnalyzer.reset()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "xmark")
                                Text("キャンセル")
                                    .fontWeight(.medium)
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(width: 140, height: 60)
                            .background(Color.gray.opacity(0.8))
                            .cornerRadius(30)
                            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                        }
                        
                        // 測定開始ボタン
                        Button(action: {
                            print("🎬 User tapped Start Recording")
                            videoAnalyzer.startRecording()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "record.circle.fill")
                                Text("測定開始")
                                    .fontWeight(.semibold)
                            }
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: 200, height: 70)
                            .background(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.red, Color.red.opacity(0.8)]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(35)
                            .shadow(color: .red.opacity(0.5), radius: 10, x: 0, y: 5)
                        }
                    }
                    .padding(.bottom, 50)
                }
            }
        }
    }
    
    // MARK: - Recording View
    private var recordingView: some View {
        GeometryReader { geometry in
            ZStack {
                // Camera preview
                CameraPreviewView(videoAnalyzer: videoAnalyzer)
                    .edgesIgnoringSafeArea(.all)
                
                // Pose overlay with trophy angles
                if let pose = videoAnalyzer.detectedPose {
                    PoseOverlayView(
                        pose: pose,
                        viewSize: geometry.size,
                        trophyPoseDetected: videoAnalyzer.trophyPoseDetected,
                        trophyAngles: videoAnalyzer.trophyAngles,
                        pelvisPosition: videoAnalyzer.pelvisPosition
                    )
                }
                
                // Ball overlay
                if let ball = videoAnalyzer.detectedBall {
                    BallOverlayView(
                        ball: ball,
                        viewSize: geometry.size
                    )
                }
                
                // Status overlay
                VStack {
                    StatusIndicatorView(
                        state: videoAnalyzer.state,
                        fps: videoAnalyzer.currentFPS,
                        watchConnected: videoAnalyzer.isWatchConnected,
                        watchSamples: videoAnalyzer.watchSamplesReceived
                    )
                    .padding(.top, 50)
                    
                    Spacer()
                    
                    // Stop button
                    Button(action: {
                        print("⏹ User tapped Stop")
                        videoAnalyzer.stopRecording()
                    }) {
                        HStack {
                            Image(systemName: "stop.fill")
                            Text("停止")
                                .fontWeight(.semibold)
                        }
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 200, height: 60)
                        .background(Color.red)
                        .cornerRadius(30)
                        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    .padding(.bottom, 50)
                }
            }
        }
    }
    
    // MARK: - Analyzing View
    private var analyzingView: some View {
        ZStack {
            // カメラプレビューを背景に表示（半透明）
            CameraPreviewView(videoAnalyzer: videoAnalyzer)
                .edgesIgnoringSafeArea(.all)
                .opacity(0.3)
            
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(2.0)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                
                Text("解析中...")
                    .font(.title2)
                    .foregroundColor(.white)
                    .shadow(color: .black, radius: 4, x: 0, y: 2)
                
                Text("しばらくお待ちください")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .shadow(color: .black, radius: 4, x: 0, y: 2)
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.black.opacity(0.7))
                    .shadow(color: .black.opacity(0.4), radius: 12)
            )
        }
    }
    
    // MARK: - Error View
    private func errorView(message: String) -> some View {
        ZStack {
            // エラー時もカメラプレビューを背景に表示
            CameraPreviewView(videoAnalyzer: videoAnalyzer)
                .edgesIgnoringSafeArea(.all)
                .opacity(0.3)
            
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.red)
                
                Text("エラー")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .shadow(color: .black, radius: 4, x: 0, y: 2)
                
                Text(message)
                    .font(.body)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .shadow(color: .black, radius: 4, x: 0, y: 2)
                
                Button(action: {
                    videoAnalyzer.reset()
                }) {
                    Text("戻る")
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(width: 150, height: 50)
                        .background(Color.blue)
                        .cornerRadius(25)
                        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                }
                .padding(.top, 20)
            }
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.black.opacity(0.7))
                    .shadow(color: .black.opacity(0.4), radius: 12)
            )
        }
    }
}

// MARK: - Camera Preview View
struct CameraPreviewView: UIViewRepresentable {
    let videoAnalyzer: VideoAnalyzer
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        
        print("🖼 Creating camera preview view")
        
        DispatchQueue.main.async {
            if let previewLayer = videoAnalyzer.getPreviewLayer() {
                print("✅ Preview layer added")
                previewLayer.frame = view.bounds
                previewLayer.videoGravity = .resizeAspectFill
                view.layer.addSublayer(previewLayer)
                context.coordinator.previewLayer = previewLayer
            } else {
                print("❌ No preview layer")
            }
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let previewLayer = context.coordinator.previewLayer {
            DispatchQueue.main.async {
                previewLayer.frame = uiView.bounds
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

// MARK: - Status Indicator View
struct StatusIndicatorView: View {
    let state: AnalysisState
    let fps: Double
    let watchConnected: Bool
    let watchSamples: Int
    
    var body: some View {
        HStack(spacing: 16) {
            // Recording indicator
            if case .recording = state {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                    
                    Text("記録中")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.6))
                .cornerRadius(20)
            }
            
            // FPS indicator
            if fps > 0 {
                Text("\(Int(fps)) fps")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(15)
            }
            
            // Watch indicator
            HStack(spacing: 6) {
                Image(systemName: watchConnected ? "applewatch" : "applewatch.slash")
                    .foregroundColor(watchConnected ? .green : .gray)
                
                if watchSamples > 0 {
                    Text("\(watchSamples)")
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.6))
            .cornerRadius(15)
            
            Spacer()
        }
        .foregroundColor(.white)
        .padding(.horizontal)
    }
}

// MARK: - Preview
#Preview {
    ContentView()
}
