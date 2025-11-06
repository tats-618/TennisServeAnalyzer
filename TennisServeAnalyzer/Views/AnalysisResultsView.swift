//
//  AnalysisResultsView.swift
//  TennisServeAnalyzer
//
//  Serve analysis results display with actionable feedback
//

import SwiftUI

// MARK: - Analysis Results View
struct AnalysisResultsView: View {
    let metrics: ServeMetrics
    let onRetry: () -> Void
    let onFinish: () -> Void
    
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
    
    // MARK: - Metrics Section
    private var metricsSection: some View {
        VStack(spacing: 16) {
            Text("各項目のスコア")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(spacing: 12) {
                metricRow(
                    title: "1. トスの安定性",
                    score: metrics.score1_tossStability,
                    rawValue: String(format: "CV: %.1f%%", metrics.tossStabilityCV * 100)
                )
                
                metricRow(
                    title: "2. 肩-骨盤の傾き",
                    score: metrics.score2_shoulderPelvisTilt,
                    rawValue: String(format: "%.1f°", metrics.shoulderPelvisTiltDeg)
                )
                
                metricRow(
                    title: "3. 膝の屈曲",
                    score: metrics.score3_kneeFlexion,
                    rawValue: String(format: "%.1f°", metrics.kneeFlexionDeg)
                )
                
                metricRow(
                    title: "4. 肘の角度",
                    score: metrics.score4_elbowAngle,
                    rawValue: String(format: "%.1f°", metrics.elbowAngleDeg)
                )
                
                metricRow(
                    title: "5. ラケットドロップ",
                    score: metrics.score5_racketDrop,
                    rawValue: String(format: "%.1f°", metrics.racketDropDeg)
                )
                
                metricRow(
                    title: "6. 体幹回旋のタイミング",
                    score: metrics.score6_trunkTiming,
                    rawValue: String(format: "相関: %.2f", metrics.trunkTimingCorrelation)
                )
                
                metricRow(
                    title: "7. トス→インパクトのタイミング",
                    score: metrics.score7_tossToImpactTiming,
                    rawValue: String(format: "%.0fms", metrics.tossToImpactMs)
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
    
    // MARK: - Action Buttons
    private var actionButtons: some View {
        VStack(spacing: 12) {
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
            
            Button(action: onFinish) {
                HStack {
                    Image(systemName: "checkmark.circle")
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
    
    // 📍 ファイルの最後（約300行目以降）を以下に置き換え

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
            } else {
                return "改善の余地があります"
            }
        }
        
        private func progressWidth(score: Int) -> CGFloat {
            let screenWidth = UIScreen.main.bounds.width - 64  // Account for padding
            return CGFloat(score) / 100.0 * screenWidth
        }
        
        private func generatePrioritizedFeedback() -> [(title: String, message: String, score: Int)] {
            let allMetrics: [(title: String, message: String, score: Int)] = [
                (title: "トスの安定性", message: "トスの高さを一定に保ちましょう。同じ位置に繰り返しトスできるよう練習しましょう。", score: metrics.score1_tossStability),
                (title: "肩-骨盤の傾き", message: "トロフィーポーズで上体をもっと傾けましょう。肩のラインが骨盤より傾くイメージです。", score: metrics.score2_shoulderPelvisTilt),
                (title: "膝の屈曲", message: "膝をもっと曲げましょう。下半身のパワーを活用できます。", score: metrics.score3_kneeFlexion),
                (title: "肘の角度", message: "トロフィーポーズで肘をもっと伸ばしましょう。腕を高く上げる意識を持ちましょう。", score: metrics.score4_elbowAngle),
                (title: "ラケットドロップ", message: "ラケットをもっと深く落としましょう。背中側により大きく引くイメージです。", score: metrics.score5_racketDrop),
                (title: "体幹回旋のタイミング", message: "体幹回旋のタイミングを調整しましょう。ラケットが落ちきってから回旋を開始します。", score: metrics.score6_trunkTiming),
                (title: "トス→インパクトのタイミング", message: "トスとインパクトのタイミングを調整しましょう。トスの高さを少し変えてみましょう。", score: metrics.score7_tossToImpactTiming)
            ]
            
            // Sort by score (ascending) and take top 2
            let sorted = allMetrics.sorted { $0.score < $1.score }
            return Array(sorted.prefix(2))
        }
    }

    // MARK: - Preview
    #Preview {
        AnalysisResultsView(
            metrics: ServeMetrics(
                tossStabilityCV: 0.08,
                shoulderPelvisTiltDeg: 15.2,
                kneeFlexionDeg: 142.3,
                elbowAngleDeg: 168.5,
                racketDropDeg: 54.1,
                trunkTimingCorrelation: 0.72,
                tossToImpactMs: 467.0,
                score1_tossStability: 78,
                score2_shoulderPelvisTilt: 92,
                score3_kneeFlexion: 88,
                score4_elbowAngle: 95,
                score5_racketDrop: 80,
                score6_trunkTiming: 58,
                score7_tossToImpactTiming: 74,
                totalScore: 81,
                timestamp: Date(),
                flags: ["sample"]
            ),
            onRetry: { print("Retry") },
            onFinish: { print("Finish") }
        )
    }
