//
//  ContentView.swift
//  TennisServeAnalyzer
//
//  Main view with analysis results integration
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var videoAnalyzer = VideoAnalyzer()
    
    var body: some View {
        ZStack {
            // Background
            Color.black.edgesIgnoringSafeArea(.all)
            
            // 🔧 修正: 常にカメラプレビューを表示（録画状態に関係なく）
            if case .idle = videoAnalyzer.state {
                CameraPreviewView(videoAnalyzer: videoAnalyzer)
                    .edgesIgnoringSafeArea(.all)
            }
            
            // Main content based on state
            switch videoAnalyzer.state {
            case .idle:
                idleOverlayView
                
            case .recording:
                recordingView
                
            case .analyzing:
                analyzingView
                
            case .completed(let metrics):
                AnalysisResultsView(
                    metrics: metrics,
                    onRetry: {
                        videoAnalyzer.reset()
                    },
                    onFinish: {
                        videoAnalyzer.reset()
                    }
                )
                
            case .error(let message):
                errorView(message: message)
            }
        }
        .onAppear {
            print("📱 ContentView appeared")
            // 🔧 追加: アプリ起動時にカメラプレビューを準備
            videoAnalyzer.prepareCameraPreview()
        }
    }
    
    // MARK: - Idle Overlay View (カメラプレビューの上に表示)
    private var idleOverlayView: some View {
        VStack {
            Spacer()
            
            // 半透明の背景でテキストを見やすく
            VStack(spacing: 16) {
                Text("Tennis Serve Analyzer")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .shadow(color: .black, radius: 4, x: 0, y: 2)
                
                Text("サーブフォームを解析します")
                    .font(.headline)
                    .foregroundColor(.white)
                    .shadow(color: .black, radius: 4, x: 0, y: 2)
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 30)
            .background(Color.black.opacity(0.6))
            .cornerRadius(20)
            
            Spacer()
            
            Button(action: {
                print("🎬 User tapped Start")
                videoAnalyzer.startRecording()
            }) {
                HStack {
                    Image(systemName: "video.fill")
                    Text("開始")
                        .fontWeight(.semibold)
                }
                .font(.title2)
                .foregroundColor(.white)
                .frame(width: 200, height: 60)
                .background(Color.blue)
                .cornerRadius(30)
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            }
            .padding(.bottom, 100)
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
            // 🔧 追加: 解析中もカメラプレビューを背景に表示
            CameraPreviewView(videoAnalyzer: videoAnalyzer)
                .edgesIgnoringSafeArea(.all)
                .opacity(0.3) // 半透明にして解析表示を見やすく
            
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(2.0)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                
                Text("解析中...")
                    .font(.title2)
                    .foregroundColor(.white)
                    .shadow(color: .black, radius: 4, x: 0, y: 2)
            }
            .padding(30)
            .background(Color.black.opacity(0.7))
            .cornerRadius(20)
        }
    }
    
    // MARK: - Error View
    private func errorView(message: String) -> some View {
        ZStack {
            // 🔧 追加: エラー時もカメラプレビューを背景に表示
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
            .background(Color.black.opacity(0.7))
            .cornerRadius(20)
        }
    }
}

// MARK: - Camera Preview View (変更なし)
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

// MARK: - Status Indicator View (変更なし)
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
