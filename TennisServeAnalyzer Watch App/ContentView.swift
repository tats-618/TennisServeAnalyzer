import SwiftUI

struct ContentView: View {
    @StateObject private var analyzer = ServeAnalyzer()
    @StateObject private var watchManager = WatchConnectivityManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {

                // ① 起動 → 接続/サンプリング確認
                headerStatusSection

                // ②〜⑦ キャリブ・ガイダンス
                calibrationSection

                // ⑧ 測定
                measureSection
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .onAppear {
            print("⌚ Watch ContentView appeared")
            // iPhoneからのリモート操作（必要に応じて）
            watchManager.onStartRecording = { [weak analyzer] in analyzer?.startRecording() }
            watchManager.onStopRecording  = { [weak analyzer] in analyzer?.stopRecording() }
            watchManager.requestTimeSyncFromPhone { ok in
                print(ok ? "✅ Time sync successful" : "⚠️ Time sync failed")
            }
        }
    }

    // MARK: - Sections

    private var headerStatusSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill((watchManager.session?.isReachable ?? false) ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(analyzer.connectionStatusText)
                    .font(.system(size: 10)).foregroundColor(.white)
                Spacer()
                Text(analyzer.samplingStatus)
                    .font(.system(size: 10)).foregroundColor(.gray)
            }
            .padding(6).background(Color.black.opacity(0.25)).cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(analyzer.statusHeader)
                    .font(.caption).fontWeight(.semibold).foregroundColor(.white)
                Text(analyzer.statusDetail)
                    .font(.system(size: 10)).foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var calibrationSection: some View {
        VStack(spacing: 8) {
            // ガイダンス
            Group {
                switch analyzer.calibStage {
                case .idle:
                    Text("キャリブ前：まず“水平キャリブレーション”")
                        .font(.system(size: 10)).foregroundColor(.gray)
                case .levelPrompt:
                    Text("指示：Watch画面を上向きにして地面に置く → “水平登録”")
                        .font(.system(size: 10)).foregroundColor(.yellow)
                case .levelDone:
                    Text("水平登録完了 → 次に“方向キャリブレーション”")
                        .font(.system(size: 10)).foregroundColor(.green)
                case .dirPrompt:
                    Text("指示：ラケットを立てて狙う方向へ面を向ける → “方向登録”")
                        .font(.system(size: 10)).foregroundColor(.yellow)
                case .dirDone:
                    Text("方向登録完了 → “キャリブ終了”で準備完了")
                        .font(.system(size: 10)).foregroundColor(.green)
                case .ready:
                    Text("キャリブ終了：準備完了。記録開始できます。")
                        .font(.system(size: 10)).foregroundColor(.cyan)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // ボタン群
            VStack(spacing: 6) {
                HStack {
                    Button("水平キャリブレーション") { analyzer.beginCalibLevel() }
                        .buttonStylePrimary(color: .blue)
                    Button("水平登録") { analyzer.commitCalibLevel() }
                        .buttonStyleSecondary(disabled: !analyzerHasStage(.levelPrompt))
                        .disabled(!analyzerHasStage(.levelPrompt))
                }

                HStack {
                    Button("方向キャリブレーション") { analyzer.beginCalibDirection() }
                        .buttonStylePrimary(color: .indigo)
                        .disabled(!analyzer.hasLevelCalib)
                    Button("方向登録") { analyzer.commitCalibDirection() }
                        .buttonStyleSecondary(disabled: !analyzerHasStage(.dirPrompt))
                        .disabled(!analyzerHasStage(.dirPrompt))
                }

                Button("キャリブレーション終了（準備完了）") { analyzer.finishCalibration() }
                    .buttonStylePrimary(color: .green)
                    .disabled(!(analyzer.hasLevelCalib && analyzer.hasDirCalib))
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.25))
        .cornerRadius(10)
    }

    private var measureSection: some View {
        VStack(spacing: 10) {
            // 面角の簡易表示（ヒット後）
            VStack(spacing: 2) {
                Text(String(format: "面角 yaw %.1f° / pitch %.1f°",
                            analyzer.lastFaceYawDeg, analyzer.lastFacePitchDeg))
                    .font(.system(size: 11)).foregroundColor(.white)

                // ★ Peak Position (r) 表示
                Text(String(format: "Peak Position r = %.3f", analyzer.lastPeakPositionR))
                    .font(.system(size: 11))
                    .foregroundColor(.cyan)

                // ★ 評価コメントも表示（必要なければこのブロックは削ってOK）
                if !analyzer.lastPeakEvalText.isEmpty {
                    Text(analyzer.lastPeakEvalText)
                        .font(.system(size: 11))
                        .foregroundColor(.yellow)
                }

                if !analyzer.lastFaceAdvice.isEmpty {
                    Text(analyzer.lastFaceAdvice)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.yellow)
                }
            }
            .padding(6).background(Color.black.opacity(0.25)).cornerRadius(8)

            // 記録ボタン（キャリブ完了で有効化）
            Button(action: {
                if analyzer.isRecording {
                    print("⏹ User tapped Stop")
                    analyzer.stopRecording()
                } else {
                    print("🎬 User tapped Start")
                    analyzer.startRecording()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: analyzer.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.caption)
                    Text(analyzer.isRecording ? "停止" : "記録開始")
                        .font(.caption).fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(analyzer.isRecording ? Color.red : (analyzer.calibStage == .ready ? Color.green : Color.gray))
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .disabled(!(analyzer.calibStage == .ready || analyzer.isRecording))
        }
    }

    // Helper
    private func analyzerHasStage(_ stage: ServeAnalyzer.CalibStage) -> Bool {
        analyzer.calibStage == stage
    }
}

// MARK: - Button Styles
fileprivate extension Button {
    func buttonStylePrimary(color: Color) -> some View {
        self.font(.system(size: 11, weight: .semibold))
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(color.opacity(0.9))
            .foregroundColor(.white)
            .cornerRadius(8)
    }
    func buttonStyleSecondary(disabled: Bool) -> some View {
        self.font(.system(size: 11, weight: .semibold))
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(disabled ? Color.gray.opacity(0.5) : Color.orange.opacity(0.9))
            .foregroundColor(.white)
            .cornerRadius(8)
    }
}

