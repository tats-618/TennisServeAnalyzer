//
//  ContentView.swift
//  TennisServeAnalyzer Watch App
//
//  🎨 Modern UI Redesign
//  - 洗練されたダッシュボードデザイン
//  - キャリブレーションのウィザード形式化
//  - 測定ボタンの完全削除（iPhoneリモート制御専用）
//

import SwiftUI

struct ContentView: View {
    @StateObject private var analyzer = ServeAnalyzer()
    @StateObject private var watchManager = WatchConnectivityManager.shared

    // 録画中の点滅アニメーション用ステート
    @State private var isPulsing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // 1. ステータスバー (接続状態・REC表示)
                statusBarSection

                // 2. メインコンテンツ (状態に応じて切り替え)
                if analyzer.calibStage == .ready || analyzer.isRecording {
                    // 測定モード（待機中または録画中）
                    measurementDashboard
                } else {
                    // キャリブレーションモード
                    calibrationWizard
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color.black) // 背景色を黒で統一
        .onAppear {
            setupConnectivity()
        }
    }

    // MARK: - Setup
    private func setupConnectivity() {
        print("⌚ Watch ContentView appeared")
        watchManager.onStartRecording = { [weak analyzer] in analyzer?.startRecording() }
        watchManager.onStopRecording  = { [weak analyzer] in analyzer?.stopRecording() }
        watchManager.requestTimeSyncFromPhone { _ in }
    }

    // MARK: - 1. Status Bar Section
    private var statusBarSection: some View {
        HStack {
            // 左側: 接続アイコン + 状態テキスト
            HStack(spacing: 6) {
                Image(systemName: (watchManager.session?.isReachable ?? false) ? "iphone.gen3" : "iphone.slash")
                    .font(.system(size: 14))
                    .foregroundColor((watchManager.session?.isReachable ?? false) ? .green : .gray)
                
                if analyzer.isRecording {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .opacity(isPulsing ? 1.0 : 0.3)
                        Text("REC")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                            isPulsing = true
                        }
                    }
                } else {
                    Text(analyzer.connectionStatusText)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // 右側: サンプリングレート
            if analyzer.effectiveSampleRate > 0 {
                Text("\(Int(analyzer.effectiveSampleRate))Hz")
                    .font(.system(size: 12, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 2. Calibration Wizard Section
    private var calibrationWizard: some View {
        VStack(spacing: 12) {
            // 進捗インジケータ（簡易版）
            HStack(spacing: 4) {
                Capsule().fill(analyzer.hasLevelCalib ? Color.blue : Color.gray.opacity(0.3)).frame(height: 4)
                Capsule().fill(analyzer.hasDirCalib ? Color.blue : Color.gray.opacity(0.3)).frame(height: 4)
                Capsule().fill((analyzer.calibStage == .ready) ? Color.green : Color.gray.opacity(0.3)).frame(height: 4)
            }
            .padding(.bottom, 4)

            // ステップごとのカード表示
            switch analyzer.calibStage {
            case .idle:
                actionCard(
                    icon: "level",
                    title: "水平キャリブレーション",
                    description: "測定を開始する前に、ラケットの水平位置を登録します。",
                    buttonTitle: "開始する",
                    color: .blue
                ) {
                    analyzer.beginCalibLevel()
                }

            case .levelPrompt:
                actionCard(
                    icon: "arrow.down.to.line.compact",
                    title: "水平登録",
                    description: "ラケット面を上にして地面に置き、登録ボタンを押してください。",
                    buttonTitle: "登録",
                    color: .blue
                ) {
                    analyzer.commitCalibLevel()
                }

            case .levelDone:
                actionCard(
                    icon: "arrow.up.and.down.and.arrow.left.and.right",
                    title: "方向キャリブレーション",
                    description: "次に、打つ方向（ターゲット）を登録します。",
                    buttonTitle: "次へ",
                    color: .orange
                ) {
                    analyzer.beginCalibDirection()
                }

            case .dirPrompt:
                actionCard(
                    icon: "location.north.line.fill",
                    title: "方向登録",
                    description: "ラケットを立てて、打つ方向に面を向けてください。",
                    buttonTitle: "登録",
                    color: .orange
                ) {
                    analyzer.commitCalibDirection()
                }

            case .dirDone:
                actionCard(
                    icon: "checkmark.seal.fill",
                    title: "設定完了",
                    description: "すべての設定が完了しました。",
                    buttonTitle: "完了して待機",
                    color: .green
                ) {
                    analyzer.finishCalibration()
                }

            default:
                EmptyView()
            }
        }
    }

    // MARK: - 3. Measurement Dashboard Section
    private var measurementDashboard: some View {
        VStack(spacing: 16) {
            // メインステータス表示
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.gray.opacity(0.15))
                
                VStack(spacing: 8) {
                    if analyzer.isRecording {
                        Image(systemName: "figure.tennis")
                            .font(.system(size: 36))
                            .foregroundColor(.white)
                        Text("測定中...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                            .font(.system(size: 28))
                            .foregroundColor(.blue)
                        Text("iPhone待機中")
                            .font(.headline)
                        Text("iPhone側で\n測定を開始してください")
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            .frame(minHeight: 120)

            // 直前のデータ表示（ヒット後のみ表示）
            if analyzer.lastPeakPositionR != 0 {
                VStack(alignment: .leading, spacing: 12) {
                    Text("LAST SHOT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    HStack {
                        metricView(label: "Roll", value: String(format: "%.0f°", analyzer.lastFaceYawDeg))
                        Divider().background(Color.gray)
                        metricView(label: "Pitch", value: String(format: "%.0f°", analyzer.lastFacePitchDeg))
                    }
                    
                    Divider().background(Color.gray.opacity(0.5))
                    
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Accel Peak (r)")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                            Text(String(format: "%.3f", analyzer.lastPeakPositionR))
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        Spacer()
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
            }
        }
    }

    // MARK: - Helper Views

    // カードスタイルのアクションビュー
    private func actionCard(icon: String, title: String, description: String, buttonTitle: String, color: Color, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.2))
                    .clipShape(Circle())
                
                Text(title)
                    .font(.headline)
                    .fontWeight(.bold)
            }
            
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            Button(action: action) {
                Text(buttonTitle)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(color)
            .padding(.top, 4)
        }
        .padding()
        .background(Color.gray.opacity(0.15))
        .cornerRadius(16)
    }

    // 数値表示用コンポーネント
    private func metricView(label: String, value: String) -> some View {
        VStack(alignment: .leading) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(.cyan)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
