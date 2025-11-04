//
//  ContentView.swift
//  TennisServeAnalyzer Watch App
//
//  Watch interface for serve recording - Compact UI
//

import SwiftUI

struct ContentView: View {
    @StateObject private var analyzer = ServeAnalyzer()
    @StateObject private var watchManager = WatchConnectivityManager.shared
    
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Title
                Text("Tennis Serve")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                // Connection status
                ConnectionStatusView(isConnected: watchManager.session?.isReachable ?? false)
                
                // Main content
                if analyzer.isRecording {
                    RecordingView(sampleCount: analyzer.currentSampleCount)
                        .padding(.vertical, 4)
                } else {
                    IdleView()
                        .padding(.vertical, 4)
                }
                
                // Control button - ALWAYS VISIBLE
                Button(action: toggleRecording) {
                    HStack(spacing: 4) {
                        Image(systemName: analyzer.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.caption)
                        Text(analyzer.isRecording ? "停止" : "記録開始")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(analyzer.isRecording ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .onAppear {
            print("⌚ Watch ContentView appeared")
            
            // Setup command callbacks
            watchManager.onStartRecording = { [weak analyzer] in
                print("▶️ Starting recording via iPhone command")
                analyzer?.startRecording()
            }
            
            watchManager.onStopRecording = { [weak analyzer] in
                print("⏹ Stopping recording via iPhone command")
                analyzer?.stopRecording()
            }
            
            // Request time sync from iPhone
            watchManager.requestTimeSyncFromPhone { success in
                print(success ? "✅ Time sync successful" : "⚠️ Time sync failed")
            }
        }
    }
    
    private func toggleRecording() {
        if analyzer.isRecording {
            print("⏹ User tapped Stop")
            analyzer.stopRecording()
        } else {
            print("🎬 User tapped Start")
            analyzer.startRecording()
        }
    }
}

// MARK: - Connection Status View (Compact)
struct ConnectionStatusView: View {
    let isConnected: Bool
    
    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            
            Text(isConnected ? "iPhone接続" : "未接続")
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.3))
        .cornerRadius(8)
    }
}

// MARK: - Idle View (Compact)
struct IdleView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "figure.tennis")
                .font(.system(size: 32))
                .foregroundColor(.blue)
            
            Text("準備完了")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white)
            
            Text("下のボタンをタップ")
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Recording View (Compact)
struct RecordingView: View {
    let sampleCount: Int
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 8) {
            // Recording indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isAnimating ? 1.2 : 1.0)
                
                Text("記録中")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
            }
            
            // Sample count
            VStack(spacing: 2) {
                Text("\(sampleCount)")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                
                Text("サンプル")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            
            // Rate indicator
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                    .font(.system(size: 10))
                
                Text("100Hz")
                    .font(.system(size: 10))
            }
            .foregroundColor(.green)
        }
        .padding(.vertical, 4)
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

#Preview {
    ContentView()
}
