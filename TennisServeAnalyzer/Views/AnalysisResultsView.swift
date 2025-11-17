//
//  AnalysisResultsView.swift
//  TennisServeAnalyzer
//
//  Serve analysis results display with actionable feedback
//  🔧 修正: セッション管理に対応
//

import SwiftUI

// MARK: - Analysis Results View
struct AnalysisResultsView: View {
    let metrics: ServeMetrics
    let onRetry: () -> Void           // 🔧 変更: setupCameraに移動
    let onEndSession: () -> Void      // 🆕 新規追加
    
    // MARK: - Body
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Total Score
                totalScoreSection
                
                // Individual Metrics
                metricsSection
                
                // Feedback
                feedbackSection
                
                // Action Buttons
                actionButtons
                
                Spacer(minLength: 40)
            }
            .padding()
        }
        .background(Color(UIColor.systemGroupedBackground))
    }
    
    // MARK: - Total Score Section
    private var totalScoreSection: some View {
        VStack(spacing: 12) {
            Text("総合スコア")
                .font(.headline)
                .foregroundColor(.secondary)
            
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 20)
                    .frame(width: 200, height: 200)
                
                Circle()
                    .trim(from: 0, to: CGFloat(metrics.totalScore) / 100)
                    .stroke(scoreColor(metrics.totalScore), lineWidth: 20)
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 1.0), value: metrics.totalScore)
                
                VStack(spacing: 4) {
                    Text("\(metrics.totalScore)")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundColor(scoreColor(metrics.totalScore))
                    
                    Text("/ 100")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
            
            Text(scoreMessage(metrics.totalScore))
                .font(.title3)
                .fontWeight(.medium)
                .foregroundColor(scoreColor(metrics.totalScore))
                .padding(.top, 8)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
    
    // MARK: - Metrics Section (8指標)
    private var metricsSection: some View {
        VStack(spacing: 16) {
            Text("各項目のスコア")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(spacing: 12) {
                metricRow(
                    title: "1. 肘の角度（トロフィーポーズ時）",
                    score: metrics.score1_elbowAngle,
                    rawValue: String(format: "%.1f°", metrics.elbowAngleDeg)
                )
                
                metricRow(
                    title: "2. 脇の角度（トロフィーポーズ時）",
                    score: metrics.score2_armpitAngle,
                    rawValue: String(format: "%.1f°", metrics.armpitAngleDeg)
                )
                
                metricRow(
                    title: "3. 下半身の貢献度（骨盤上昇）",
                    score: metrics.score3_lowerBodyContribution,
                    rawValue: String(format: "%.0fpx", metrics.pelvisRisePx)
                )
                
                metricRow(
                    title: "4. 左手位置（左肩/左肘）",
                    score: metrics.score4_leftHandPosition,
                    rawValue: String(format: "左肩: %.1f° / 左肘: %.1f°",
                                     metrics.leftArmTorsoAngleDeg,
                                     metrics.leftArmExtensionDeg)
                )
                
                metricRow(
                    title: "5. 体の軸の傾き（インパクト）",
                    score: metrics.score5_bodyAxisTilt,
                    rawValue: String(format: "Δθ=%.1f°", metrics.bodyAxisDeviationDeg)
                )
                
                metricRow(
                    title: "6. ラケット面の向き（インパクト）",
                    score: metrics.score6_racketFaceAngle,
                    rawValue: String(format: "左右: %.1f° / 上下: %.1f°",
                                     metrics.racketFaceYawDeg,
                                     metrics.racketFacePitchDeg)
                )
                
                metricRow(
                    title: "7. トスの位置",
                    score: metrics.score7_tossPosition,
                    rawValue: String(format: "前方: %.2fm, 横: %.0fpx (%@)",
                                     metrics.tossForwardDistanceM,
                                     abs(metrics.tossOffsetFromCenterPx),
                                     metrics.tossOffsetFromCenterPx >= 0 ? "右" : "左")
                )
                
                metricRow(
                    title: "8. リストワーク",
                    score: metrics.score8_wristwork,
                    rawValue: String(format: "%.0f°", metrics.wristRotationDeg)
                )
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
    
    private func metricRow(title: String, score: Int, rawValue: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Text("\(score)")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(scoreColor(score))
            }
            
            ZStack(alignment: .leading) {
                // Background bar
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 8)
                
                // Progress bar
                RoundedRectangle(cornerRadius: 4)
                    .fill(scoreColor(score))
                    .frame(width: progressWidth(score: score), height: 8)
                    .animation(.easeInOut(duration: 0.8), value: score)
            }
            
            Text(rawValue)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Feedback Section
    private var feedbackSection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.orange)
                
                Text("改善ポイント")
                    .font(.headline)
                
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 16) {
                // Get top 2 lowest scores
                let feedback = generatePrioritizedFeedback()
                
                ForEach(Array(feedback.enumerated()), id: \.offset) { index, item in
                    feedbackCard(
                        rank: index + 1,
                        title: item.title,
                        message: item.message,
                        score: item.score
                    )
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
    
    private func feedbackCard(rank: Int, title: String, message: String, score: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Rank badge
            ZStack {
                Circle()
                    .fill(scoreColor(score))
                    .frame(width: 32, height: 32)
                
                Text("\(rank)")
                    .font(.headline)
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
        .padding()
        .background(Color(UIColor.tertiarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    // MARK: - 🔧 修正: Action Buttons
    private var actionButtons: some View {
        VStack(spacing: 12) {
            // 🔧 変更: カメラセッティング画面に直接移動
            Button(action: onRetry) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("もう一度試す")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            
            // 🆕 新規: セッション終了ボタン
            Button(action: onEndSession) {
                HStack {
                    Image(systemName: "chart.bar.fill")
                    Text("セッション終了")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .foregroundColor(.blue)
                .cornerRadius(12)
            }
        }
    }
    
    // MARK: - Helper Functions
    private func scoreColor(_ score: Int) -> Color {
        if score >= 80 {
            return Color(red: 0x3C / 255.0, green: 0xC7 / 255.0, blue: 0x6A / 255.0)  // Green
        } else if score >= 60 {
            return Color(red: 0xF7 / 255.0, green: 0xC7 / 255.0, blue: 0x44 / 255.0)  // Yellow
        } else {
            return Color(red: 0xE8 / 255.0, green: 0x5C / 255.0, blue: 0x5C / 255.0)  // Red
        }
    }
    
    private func scoreMessage(_ score: Int) -> String {
        if score >= 80 {
            return "素晴らしい！"
        } else if score >= 60 {
            return "良いフォームです"
        } else if score >= 40 {
            return "改善の余地があります"
        } else {
            return "努力が必要です"
        }
    }
    
    private func progressWidth(score: Int) -> CGFloat {
        let screenWidth = UIScreen.main.bounds.width - 64  // Account for padding
        return CGFloat(score) / 100.0 * screenWidth
    }
    
    private func generatePrioritizedFeedback() -> [(title: String, message: String, score: Int)] {
        // v0.2の8指標に対応
        let all: [(title: String, message: String, score: Int)] = [
            (
                title: "肘の角度",
                message: "トロフィーポーズで肘をもう少し伸ばし、高く構えましょう。",
                score: metrics.score1_elbowAngle
            ),
            (
                title: "脇の角度",
                message: "上腕と体幹の間を保ち、胸郭を開きすぎ/詰めすぎに注意。",
                score: metrics.score2_armpitAngle
            ),
            (
                title: "下半身の貢献度",
                message: "膝を深く曲げて骨盤を60~70px上昇させましょう。リズムよく伸展して下半身のパワーを活かしましょう。",
                score: metrics.score3_lowerBodyContribution
            ),
            (
                title: "左手位置",
                message: "左腕を体幹前で高く保ち、肘は適度に伸展してトスの安定を。",
                score: metrics.score4_leftHandPosition
            ),
            (
                title: "体軸の傾き",
                message: "インパクトで腰角・膝角が一直線に近づくように体幹を安定。",
                score: metrics.score5_bodyAxisTilt
            ),
            (
                title: "ラケット面の向き",
                message: "インパクト直前のYaw/Pitchを0付近に収束させ、面ブレを抑制。",
                score: metrics.score6_racketFaceAngle
            ),
            (
                title: "トスの位置",
                message: "前方0.2–0.6mを目安に。コートキャリブ後に再調整を。",
                score: metrics.score7_tossPosition
            ),
            (
                title: "リストワーク",
                message: "総回転120–220°を目安に。過小/過多はいずれも球威低下要因。",
                score: metrics.score8_wristwork
            )
        ]
        
        // Score昇順でワースト2を返す
        return Array(all.sorted { $0.score < $1.score }.prefix(2))
    }
}

// MARK: - Preview
#Preview {
    let sample = ServeMetrics(
        elbowAngleDeg: 168.5,
        armpitAngleDeg: 92.0,
        pelvisRisePx: 65.0,
        leftArmTorsoAngleDeg: 65.0,
        leftArmExtensionDeg: 170.0,
        bodyAxisDeviationDeg: 6.2,
        racketFaceYawDeg: 8.5,
        racketFacePitchDeg: 6.0,
        tossForwardDistanceM: 0.35,
        wristRotationDeg: 180.0,
        tossPositionX: 760.0,
        tossOffsetFromCenterPx: 120.0,
        score1_elbowAngle: 95,
        score2_armpitAngle: 88,
        score3_lowerBodyContribution: 90,
        score4_leftHandPosition: 84,
        score5_bodyAxisTilt: 78,
        score6_racketFaceAngle: 86,
        score7_tossPosition: 92,
        score8_wristwork: 80,
        totalScore: 86,
        timestamp: Date(),
        flags: []
    )
    
    AnalysisResultsView(
        metrics: sample,
        onRetry: { print("Retry") },
        onEndSession: { print("End Session") }
    )
}
