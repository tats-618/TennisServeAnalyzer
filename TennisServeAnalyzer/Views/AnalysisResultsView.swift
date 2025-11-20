//
//  AnalysisResultsView.swift
//  TennisServeAnalyzer
//
//  Serve analysis results display with actionable feedback
//  🔧 v0.3 — 設計書に基づきフィードバック文言と判定ロジックを完全準拠へ修正
//

import SwiftUI

// MARK: - Analysis Results View
struct AnalysisResultsView: View {
    let metrics: ServeMetrics
    let onRetry: () -> Void
    let onEndSession: () -> Void
    
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
                    title: "1. 肘の角度（トロフィーポーズ）",
                    score: metrics.score1_elbowAngle,
                    rawValue: String(format: "%.1f°", metrics.elbowAngleDeg)
                )
                
                metricRow(
                    title: "2. 脇の角度（トロフィーポーズ）",
                    score: metrics.score2_armpitAngle,
                    rawValue: String(format: "%.1f°", metrics.armpitAngleDeg)
                )
                
                metricRow(
                    title: "3. 下半身貢献度（骨盤上昇）",
                    score: metrics.score3_lowerBodyContribution,
                    rawValue: String(format: "%.0fpx", metrics.pelvisRisePx)
                )
                
                metricRow(
                    title: "4. 左手位置（左肩/左肘）",
                    score: metrics.score4_leftHandPosition,
                    rawValue: String(format: "左肩: %.0f° / 左肘: %.0f°",
                                     metrics.leftArmTorsoAngleDeg,
                                     metrics.leftArmExtensionDeg)
                )
                
                metricRow(
                    title: "5. 体軸傾き（インパクト）",
                    score: metrics.score5_bodyAxisTilt,
                    rawValue: String(format: "Δθ=%.1f°", metrics.bodyAxisDeviationDeg)
                )
                
                metricRow(
                    title: "6. ラケット面角（インパクト）",
                    score: metrics.score6_racketFaceAngle,
                    rawValue: String(format: "LR: %.0f° / UD: %.0f°",
                                     metrics.racketFaceYawDeg,
                                     metrics.racketFacePitchDeg)
                )
                
                metricRow(
                    title: "7. トス位置（基準線オフセット）",
                    score: metrics.score7_tossPosition,
                    rawValue: String(format: "%@%.0fpx",
                                     metrics.tossOffsetFromBaselinePx >= 0 ? "+" : "",
                                     metrics.tossOffsetFromBaselinePx)
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
                // 🔧 修正: 設計書に基づいた動的フィードバック生成
                let feedback = generatePrioritizedFeedback()
                
                if feedback.isEmpty {
                    Text("素晴らしいフォームです！この調子で練習を続けましょう。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                } else {
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
        if score >= 80 { return "素晴らしい！" }
        if score >= 60 { return "良いフォームです" }
        if score >= 40 { return "改善の余地があります" }
        return "努力が必要です"
    }
    
    private func progressWidth(score: Int) -> CGFloat {
        let screenWidth = UIScreen.main.bounds.width - 64
        return CGFloat(score) / 100.0 * screenWidth
    }
    
    // MARK: - 🔧 Feedback Generation Logic (Based on Design PDF)
    private func generatePrioritizedFeedback() -> [(title: String, message: String, score: Int)] {
        var feedbackList: [(title: String, message: String, score: Int)] = []
        
        // 1. 右肘角度 [cite: 4-11]
        if metrics.score1_elbowAngle < 100 {
            // 360度系の場合は正規化が必要だが、ここではMetrics計算側で正規化済みと仮定するか、
            // シンプルに設計書の境界値を使用。
            // NOTE: 設計書では <89.9 or >110.1 で判定
            let angle = normalizeAngle(metrics.elbowAngleDeg)
            if angle < 90.0 {
                feedbackList.append((
                    title: "右肘の角度",
                    message: "トロフィーポーズの時に右肘が曲がりすぎています。もっと肘を開きましょう。",
                    score: metrics.score1_elbowAngle
                ))
            } else if angle > 110.0 {
                feedbackList.append((
                    title: "右肘の角度",
                    message: "トロフィーポーズの時に右肘が伸びすぎています。もっと肘を曲げましょう。",
                    score: metrics.score1_elbowAngle
                ))
            }
        }
        
        // 2. 右脇角度 [cite: 12-20]
        if metrics.score2_armpitAngle < 100 {
            let angle = metrics.armpitAngleDeg
            // 設計書: 90<=θ<170: 下がりすぎ, 190<θ<=270: 上がりすぎ
            if angle >= 90 && angle < 170 {
                feedbackList.append((
                    title: "右脇の角度",
                    message: "トロフィーポーズの時に右肘が下がりすぎています。もっと肘を上げましょう。",
                    score: metrics.score2_armpitAngle
                ))
            } else if angle > 190 && angle <= 270 {
                feedbackList.append((
                    title: "右脇の角度",
                    message: "トロフィーポーズの時に右肘が上がりすぎています。もっと肘を下げましょう。",
                    score: metrics.score2_armpitAngle
                ))
            }
        }
        
        // 3. 下半身貢献度 [cite: 21-26]
        if metrics.score3_lowerBodyContribution < 100 {
            let rise = metrics.pelvisRisePx
            // 設計書: 0 < 50px (膝が曲がっていない)
            if rise < 50.0 {
                feedbackList.append((
                    title: "下半身貢献度",
                    message: "下半身のパワーが使えていません。膝を曲げて上にしっかり飛びましょう。",
                    score: metrics.score3_lowerBodyContribution
                ))
            }
        }
        
        // 4. 左手位置 [cite: 27-33]
        if metrics.score4_leftHandPosition < 100 {
            let shoulder = metrics.leftArmTorsoAngleDeg
            let elbow = normalizeAngle(metrics.leftArmExtensionDeg) // 180度正規化と仮定
            
            var msgs: [String] = []
            // i. 左肩判定
            if (shoulder >= 0 && shoulder < 90) || (shoulder > 120 && shoulder < 270) {
                msgs.append("トロフィーポーズの時は左腕を真上に伸ばしましょう。")
            }
            // ii. 左肘判定 (設計書: 0 <= θ < 170)
            if elbow >= 0 && elbow < 170 {
                msgs.append("トロフィーポーズの時は左腕を曲げずに真上に伸ばしましょう。")
            }
            
            if !msgs.isEmpty {
                feedbackList.append((
                    title: "左手位置",
                    message: msgs.joined(separator: "\n"), // 複数該当時は改行で結合
                    score: metrics.score4_leftHandPosition
                ))
            }
        }
        
        // 5. 体軸傾き [cite: 34-42]
        if metrics.score5_bodyAxisTilt < 100 {
            let delta = metrics.bodyAxisDeviationDeg
            // 設計書: Δθ > 15.1
            if delta > 15.0 {
                feedbackList.append((
                    title: "体軸の傾き",
                    message: "体が折れ曲がっています。ボールを打つ瞬間は体軸を真っ直ぐに保ちましょう。",
                    score: metrics.score5_bodyAxisTilt
                ))
            }
        }
        
        // 6. ラケット面角 [cite: 43-55]
        if metrics.score6_racketFaceAngle < 100 {
            let roll = metrics.racketFaceYawDeg
            let pitch = metrics.racketFacePitchDeg
            var msgs: [String] = []
            
            // i. Roll Left (-60 <= r < -5.1)
            if roll >= -60 && roll < -5.0 {
                msgs.append("ボールを打つ時にラケット面が左を向いています。真っ直ぐ打ちたい方向に向けましょう。")
            }
            // ii. Roll Right (+5.1 < r <= +60)
            else if roll > 5.0 && roll <= 60 {
                msgs.append("ボールを打つ時にラケット面が右を向いています。真っ直ぐ打ちたい方向に向けましょう。")
            }
            
            // iii. Pitch Down (-60 <= p < -10.1)
            if pitch >= -60 && pitch < -10.0 {
                msgs.append("ラケット面が下を向いています。ボールがネットにかかりやすいです。")
            }
            // iv. Pitch Up (+10.1 < p <= +60)
            else if pitch > 10.0 && pitch <= 60 {
                msgs.append("ラケット面が上を向いています。高い打点で腕を伸ばして打ってみましょう。")
            }
            
            if !msgs.isEmpty {
                feedbackList.append((
                    title: "ラケット面の向き",
                    message: msgs.joined(separator: "\n"),
                    score: metrics.score6_racketFaceAngle
                ))
            }
        }
        
        // 7. トス位置 [cite: 56-63]
        if metrics.score7_tossPosition < 100 {
            let u_user = metrics.tossOffsetFromBaselinePx
            
            // i. トスが後ろ (46px > u_user)
            // 設計書では -54 < u < 46 の範囲が「後ろすぎ」判定エリア
            if u_user < 46.0 {
                 feedbackList.append((
                    title: "トスの位置",
                    message: "トスが後ろすぎます。前に上げて打ち下ろすように打ってみましょう。",
                    score: metrics.score7_tossPosition
                ))
            }
            // ii. トスが前 (u_user > 57px)
            // 設計書では 57 < u < 157 の範囲が「前すぎ」判定エリア
            else if u_user > 57.0 {
                feedbackList.append((
                    title: "トスの位置",
                    message: "トスが前に行きすぎです。もう少しトスを後ろに上げてみましょう。",
                    score: metrics.score7_tossPosition
                ))
            }
        }
        
        // 8. リストワーク (設計書テキストなし、既存ロジック維持)
        if metrics.score8_wristwork < 60 {
             feedbackList.append((
                title: "リストワーク",
                message: "手首の回内・回外動作がスムーズに使えていません。リラックスしてスイングしましょう。",
                score: metrics.score8_wristwork
            ))
        }

        // スコアが低い順（改善が必要な順）にソートし、上位2つを返す
        return Array(feedbackList.sorted { $0.score < $1.score }.prefix(2))
    }
    
    // Helper for angle normalization if needed
    private func normalizeAngle(_ angle: Double) -> Double {
        if angle <= 180.0 { return angle }
        return 360.0 - angle
    }
}

// MARK: - Preview
#Preview {
    let sample = ServeMetrics(
        elbowAngleDeg: 168.5, // 伸びすぎ -> Feedback対象
        armpitAngleDeg: 92.0, // 下がりすぎ -> Feedback対象
        pelvisRisePx: 45.0,   // 不足 -> Feedback対象
        leftArmTorsoAngleDeg: 65.0,
        leftArmExtensionDeg: 170.0,
        bodyAxisDeviationDeg: 6.2,
        racketFaceYawDeg: 8.5,
        racketFacePitchDeg: 6.0,
        tossOffsetFromBaselinePx: -10.0, // 後ろすぎ -> Feedback対象
        wristRotationDeg: 180.0,
        tossPositionX: 760.0,
        tossOffsetFromCenterPx: 120.0,
        score1_elbowAngle: 40,
        score2_armpitAngle: 40,
        score3_lowerBodyContribution: 90, // 計算上は45pxだと90点
        score4_leftHandPosition: 84,
        score5_bodyAxisTilt: 78,
        score6_racketFaceAngle: 86,
        score7_tossPosition: 45,
        score8_wristwork: 80,
        totalScore: 65,
        timestamp: Date(),
        flags: []
    )
    
    AnalysisResultsView(
        metrics: sample,
        onRetry: { print("Retry") },
        onEndSession: { print("End Session") }
    )
}
