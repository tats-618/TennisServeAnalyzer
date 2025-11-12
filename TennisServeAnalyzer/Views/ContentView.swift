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
            
            // Main content based on state
            switch videoAnalyzer.state {
            case .idle:
                idleView
                
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
        }
    }
    
    // MARK: - Idle View
    private var idleView: some View {
        VStack {
            Spacer()
            
            Text("Tennis Serve Analyzer")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("サーブフォームを解析します")
                .font(.headline)
                .foregroundColor(.gray)
                .padding(.top, 8)
            
            Spacer()
            
            Button(action: {
                print("🎬 User tapped Start")
                videoAnalyzer.startSession()
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
                
                // Pose overlay with trophy angles (修正: trophyAnglesパラメータを追加)
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
                    }
                    .padding(.bottom, 50)
                }
            }
        }
    }
    
    // MARK: - Analyzing View
    private var analyzingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(2.0)
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
            
            Text("解析中...")
                .font(.title2)
                .foregroundColor(.white)
        }
    }
    
    // MARK: - Error View
    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)
            
            Text("エラー")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text(message)
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button(action: {
                videoAnalyzer.reset()
            }) {
                Text("戻る")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(width: 150, height: 50)
                    .background(Color.blue)
                    .cornerRadius(25)
            }
            .padding(.top, 20)
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
