//
//  ContentView.swift
//  TennisServeAnalyzer
//
//  With Real-time Pose Overlay
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var videoAnalyzer = VideoAnalyzer()
    
    var body: some View {
        ZStack {
            // カメラプレビュー
            CameraPreviewView(videoAnalyzer: videoAnalyzer)
                .edgesIgnoringSafeArea(.all)
            
            // 骨格オーバーレイ（録画中のみ）
            if case .recording = videoAnalyzer.state {
                GeometryReader { geometry in
                    PoseOverlayView(
                        pose: videoAnalyzer.detectedPose,
                        viewSize: geometry.size,
                        trophyPoseDetected: videoAnalyzer.trophyPoseDetected
                    )
                }
                .edgesIgnoringSafeArea(.all)
            }
            
            // ボール検出オーバーレイ（録画中のみ）
            if case .recording = videoAnalyzer.state {
                GeometryReader { geometry in
                    BallOverlayView(
                        ball: videoAnalyzer.detectedBall,
                        viewSize: geometry.size
                    )
                }
                .edgesIgnoringSafeArea(.all)
            }
            
            // オーバーレイUI
            VStack {
                // トップバー
                TopStatusBar(
                    analysisState: videoAnalyzer.state,
                    fps: videoAnalyzer.currentFPS,
                    isWatchConnected: videoAnalyzer.isWatchConnected,
                    watchSamplesReceived: videoAnalyzer.watchSamplesReceived
                )
                .padding()
                .background(Color.black.opacity(0.6))
                
                Spacer()
                
                // メイン表示
                MainDisplayArea(videoAnalyzer: videoAnalyzer)
                
                Spacer()
                
                // ボトムコントロール
                BottomControlBar(videoAnalyzer: videoAnalyzer)
                    .padding()
            }
        }
        .onAppear {
            print("📱 ContentView appeared")
        }
    }
}

// MARK: - Camera Preview
struct CameraPreviewView: UIViewRepresentable {
    let videoAnalyzer: VideoAnalyzer
    
    func makeUIView(context: Context) -> UIView {
        print("🖼 Creating camera preview view")
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        
        if let previewLayer = videoAnalyzer.getPreviewLayer() {
            previewLayer.frame = view.bounds
            previewLayer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(previewLayer)
            context.coordinator.previewLayer = previewLayer
            print("✅ Preview layer added")
        } else {
            print("⚠️ No preview layer available")
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

// MARK: - Top Status Bar
struct TopStatusBar: View {
    let analysisState: AnalysisState
    let fps: Double
    let isWatchConnected: Bool
    let watchSamplesReceived: Int
    
    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                
                Text(statusText)
                    .font(.headline)
                    .foregroundColor(.white)
            }
            
            Spacer()
            
            // Watch connection indicator
            if isWatchConnected {
                HStack(spacing: 4) {
                    Image(systemName: "applewatch")
                        .font(.caption2)
                    Text("\(watchSamplesReceived)")
                        .font(.caption2)
                }
                .foregroundColor(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.2))
                .cornerRadius(4)
            }
            
            if fps > 0 {
                Text("\(Int(fps)) fps")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(fpsColor)
                    .cornerRadius(4)
            }
        }
    }
    
    private var statusText: String {
        switch analysisState {
        case .idle:
            return "準備完了"
        case .recording:
            return "記録中 🎥"
        case .analyzing:
            return "解析中..."
        case .completed(_):
            return "解析完了"
        case .error(_):
            return "エラー"
        }
    }
    
    private var statusColor: Color {
        switch analysisState {
        case .idle:
            return .blue
        case .recording:
            return .red
        case .analyzing:
            return .orange
        case .completed(_):
            return .green
        case .error(_):
            return .red
        }
    }
    
    private var fpsColor: Color {
        if fps >= 100 {
            return Color.green.opacity(0.8)
        } else if fps >= 60 {
            return Color.yellow.opacity(0.8)
        } else {
            return Color.orange.opacity(0.8)
        }
    }
}

// MARK: - Main Display Area
struct MainDisplayArea: View {
    @ObservedObject var videoAnalyzer: VideoAnalyzer
    
    var body: some View {
        VStack(spacing: 16) {
            switch videoAnalyzer.state {
            case .idle:
                IdleView()
                
            case .recording:
                RecordingView(
                    poseDetected: videoAnalyzer.detectedPose != nil,
                    ballDetected: videoAnalyzer.detectedBall != nil,
                    trophyPoseDetected: videoAnalyzer.trophyPoseDetected
                )
                
            case .analyzing:
                AnalyzingView()
                
            case .completed(let metrics):
                ResultsView(metrics: metrics)
                
            case .error(let message):
                ErrorView(message: message)
            }
        }
        .padding()
    }
}

// MARK: - Bottom Control Bar
struct BottomControlBar: View {
    @ObservedObject var videoAnalyzer: VideoAnalyzer
    
    var body: some View {
        VStack(spacing: 12) {
            Button(action: mainAction) {
                HStack {
                    Image(systemName: buttonIcon)
                    Text(buttonText)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(buttonColor)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(isButtonDisabled)
            
            if case .completed(_) = videoAnalyzer.state {
                Button("新しい記録") {
                    videoAnalyzer.reset()
                }
                .foregroundColor(.blue)
            }
        }
    }
    
    private func mainAction() {
        switch videoAnalyzer.state {
        case .idle:
            print("🎬 User tapped Start")
            videoAnalyzer.startSession()
        case .recording:
            print("⏹ User tapped Stop")
            videoAnalyzer.stopRecording()
        case .completed(_):
            videoAnalyzer.reset()
        default:
            break
        }
    }
    
    private var buttonText: String {
        switch videoAnalyzer.state {
        case .idle:
            return "サーブ記録開始"
        case .recording:
            return "記録停止"
        case .analyzing:
            return "解析中..."
        case .completed(_):
            return "完了"
        case .error(_):
            return "再試行"
        }
    }
    
    private var buttonIcon: String {
        switch videoAnalyzer.state {
        case .idle:
            return "play.circle.fill"
        case .recording:
            return "stop.circle.fill"
        case .completed(_):
            return "checkmark.circle.fill"
        default:
            return "hourglass"
        }
    }
    
    private var buttonColor: Color {
        switch videoAnalyzer.state {
        case .idle:
            return .green
        case .recording:
            return .red
        case .completed(_):
            return .blue
        case .error(_):
            return .orange
        default:
            return .gray
        }
    }
    
    private var isButtonDisabled: Bool {
        switch videoAnalyzer.state {
        case .analyzing:
            return true
        default:
            return false
        }
    }
}

// MARK: - Sub Views

struct IdleView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.circle")
                .font(.system(size: 60))
                .foregroundColor(.white)
            
            Text("準備完了")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("下のボタンでサーブ記録を開始")
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
            
            Text("録画中は骨格がリアルタイム表示されます")
                .font(.caption)
                .foregroundColor(.green)
        }
        .padding(32)
        .background(Color.black.opacity(0.6))
        .cornerRadius(16)
    }
}

struct RecordingView: View {
    let poseDetected: Bool
    let ballDetected: Bool
    let trophyPoseDetected: Bool
    
    var body: some View {
        VStack(spacing: 12) {
            // Recording indicator
            HStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 16, height: 16)
                Text("記録中")
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding()
            .background(Color.black.opacity(0.6))
            .cornerRadius(12)
            
            // Trophy Pose Indicator (prominent)
            if trophyPoseDetected {
                TrophyPoseBadge()
                    .transition(.scale.combined(with: .opacity))
            }
            
            // Detection badges
            HStack(spacing: 16) {
                DetectionBadge(
                    icon: "figure.stand",
                    label: "骨格",
                    detected: poseDetected
                )
                
                DetectionBadge(
                    icon: "tennisball",
                    label: "ボール",
                    detected: ballDetected
                )
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: trophyPoseDetected)
    }
}

struct DetectionBadge: View {
    let icon: String
    let label: String
    let detected: Bool
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(detected ? .green : .gray)
            
            Text(label)
                .font(.caption2)
                .foregroundColor(.white)
        }
        .padding(8)
        .background(Color.black.opacity(0.5))
        .cornerRadius(8)
    }
}

struct TrophyPoseBadge: View {
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trophy.fill")
                .font(.title)
                .foregroundColor(.yellow)
                .scaleEffect(isAnimating ? 1.2 : 1.0)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("🏆 トロフィーポーズ")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("完璧なフォーム！")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.yellow.opacity(0.8), Color.orange.opacity(0.8)]),
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .cornerRadius(16)
        .shadow(color: .yellow.opacity(0.5), radius: 10)
        .onAppear {
            withAnimation(
                Animation.easeInOut(duration: 0.6)
                    .repeatForever(autoreverses: true)
            ) {
                isAnimating = true
            }
        }
    }
}

struct AnalyzingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(2)
                .tint(.white)
            
            Text("解析中...")
                .font(.headline)
                .foregroundColor(.white)
        }
        .padding(32)
        .background(Color.black.opacity(0.6))
        .cornerRadius(16)
    }
}

struct ResultsView: View {
    let metrics: ServeMetrics
    
    var body: some View {
        VStack(spacing: 16) {
            Text("\(metrics.totalScore)")
                .font(.system(size: 80, weight: .bold))
                .foregroundColor(.white)
            
            Text("総合スコア")
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))
            
            Text(MetricsCalculator.generateFeedback(metrics: metrics))
                .font(.body)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding()
                .background(Color.blue.opacity(0.3))
                .cornerRadius(12)
            
            // フラグ表示（デバッグ用）
            if !metrics.flags.isEmpty {
                Text("Flags: \(metrics.flags.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding()
        .background(Color.black.opacity(0.6))
        .cornerRadius(16)
    }
}

struct ErrorView: View {
    let message: String
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.red)
            
            Text("エラー")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text(message)
                .font(.body)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .background(Color.black.opacity(0.6))
        .cornerRadius(16)
    }
}

#Preview {
    ContentView()
}
