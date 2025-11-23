//
//  SessionSummaryView.swift
//  TennisServeAnalyzer
//
//  v0.2 metrics (8-items) compatible
//  🎨 UI大幅改善版、トス位置表示を基準線ベースに変更
//

import SwiftUI

struct SessionSummaryView: View {
    let serves: [ServeMetrics]
    let onNewSession: () -> Void
    
    @State private var showStats = false
    
    private var firstServe: ServeMetrics? { serves.first }
    private var lastServe: ServeMetrics?  { serves.last  }
    
    var body: some View {
        ZStack {
            // グラデーション背景
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(UIColor.systemBackground),
                    Color(UIColor.systemGroupedBackground)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 28) {
                    // ヘッダーセクション
                    headerSection
                        .padding(.top, 20)
                    
                    // スコア比較カード
                    if let first = firstServe, let last = lastServe {
                        scoreComparisonCard(first: first, last: last)
                    }
                    
                    // レーダーチャート
                    if let first = firstServe, let last = lastServe {
                        radarChartSection(first: first, last: last)
                    }
                    
                    // 統計サマリー
                    statisticsSummarySection
                    
                    // 詳細スコアテーブル
                    detailedScoreSection
                    
                    // エクスポートセクション
                    exportSection
                    
                    // アクションボタン
                    actionButtonsSection
                    
                    Spacer(minLength: 40)
                }
                .padding(.horizontal)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                showStats = true
            }
        }
    }
    
    // MARK: - ヘッダーセクション
    private var headerSection: some View {
        VStack(spacing: 16) {
            // アイコンとタイトル
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [.green, .blue]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 60, height: 60)
                        .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)
                    
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("セッション完了")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 8) {
                        Image(systemName: "tennis.racket")
                            .foregroundColor(.green)
                        Text("\(serves.count)本のサーブを記録")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // セッション時間
            if let first = serves.first, let last = serves.last {
                let duration = last.timestamp.timeIntervalSince(first.timestamp)
                HStack {
                    Image(systemName: "clock.fill")
                        .foregroundColor(.orange)
                    Text("セッション時間: \(formatDuration(duration))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
    }
    
    // MARK: - スコア比較カード
    private func scoreComparisonCard(first: ServeMetrics, last: ServeMetrics) -> some View {
        let scoreDiff = last.totalScore - first.totalScore
        
        return VStack(spacing: 20) {
            Text("スコア比較")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 20) {
                // 初球スコア
                ScoreCardImproved(
                    title: "初球",
                    score: first.totalScore,
                    color: .pink,
                    icon: "1.circle.fill"
                )
                
                // 矢印と差分
                VStack(spacing: 8) {
                    Image(systemName: scoreDiff >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(scoreDiff >= 0 ? .green : .red)
                        .scaleEffect(showStats ? 1.0 : 0.5)
                        .animation(.spring(response: 0.6, dampingFraction: 0.6), value: showStats)
                    
                    Text("\(scoreDiff >= 0 ? "+" : "")\(scoreDiff)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(scoreDiff >= 0 ? .green : .red)
                    
                    Text(scoreDiff >= 0 ? "改善" : "低下")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                // 最終スコア
                ScoreCardImproved(
                    title: "最終",
                    score: last.totalScore,
                    color: .blue,
                    icon: "\(serves.count).circle.fill"
                )
            }
            
            // パーセンテージ改善
            if scoreDiff != 0 && first.totalScore > 0 {
                let percentChange = (Double(scoreDiff) / Double(first.totalScore)) * 100
                HStack {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundColor(.green)
                    Text("改善率: \(String(format: "%.1f", abs(percentChange)))%")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .opacity(showStats ? 1.0 : 0.0)
                .animation(.easeIn(duration: 0.5).delay(0.3), value: showStats)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
    }
    
    // MARK: - レーダーチャートセクション
    private func radarChartSection(first: ServeMetrics, last: ServeMetrics) -> some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.blue)
                Text("パフォーマンス比較")
                    .font(.headline)
                Spacer()
            }
            
            RadarChartView(
                metrics: extractMetrics(from: last),
                referenceMetrics: extractMetrics(from: first)
            )
            .frame(height: 320)
            .padding(.vertical, 8)
            
            HStack(spacing: 24) {
                LegendItemImproved(color: .blue, label: "最終球", icon: "circle.fill")
                LegendItemImproved(color: .pink, label: "初球", icon: "circle.fill")
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
    }
    
    // MARK: - 統計サマリーセクション
    private var statisticsSummarySection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundColor(.orange)
                Text("統計サマリー")
                    .font(.headline)
                Spacer()
            }
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                StatCard(
                    title: "平均スコア",
                    value: String(format: "%.1f", averageScore),
                    icon: "chart.bar.fill",
                    color: .blue
                )
                
                StatCard(
                    title: "最高スコア",
                    value: "\(maxScore)",
                    icon: "star.fill",
                    color: .yellow
                )
                
                StatCard(
                    title: "最低スコア",
                    value: "\(minScore)",
                    icon: "arrow.down.circle.fill",
                    color: .orange
                )
                
                StatCard(
                    title: "標準偏差",
                    value: String(format: "%.1f", standardDeviation),
                    icon: "waveform.path.ecg",
                    color: .purple
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
        .opacity(showStats ? 1.0 : 0.0)
        .animation(.easeIn(duration: 0.5).delay(0.2), value: showStats)
    }
    
    // MARK: - 詳細スコアセクション
    private var detailedScoreSection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "tablecells.fill")
                    .foregroundColor(.green)
                Text("詳細スコア")
                    .font(.headline)
                Spacer()
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                ScoreTableImproved(serves: serves)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
    }
    
    // MARK: - エクスポートセクション
    private var exportSection: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "square.and.arrow.up.fill")
                    .foregroundColor(.blue)
                Text("データエクスポート")
                    .font(.headline)
                Spacer()
            }
            
            HStack(spacing: 12) {
                ExportButton(
                    title: "JSON",
                    icon: "doc.text.fill",
                    color: .blue,
                    action: { exportJSON() }
                )
                
                ExportButton(
                    title: "CSV",
                    icon: "tablecells.fill",
                    color: .green,
                    action: { exportCSV() }
                )
                
                ExportButton(
                    title: "共有",
                    icon: "square.and.arrow.up",
                    color: .orange,
                    action: { shareResults() }
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
    }
    
    // MARK: - アクションボタンセクション
    private var actionButtonsSection: some View {
        VStack(spacing: 12) {
            Button(action: onNewSession) {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                    Text("新しいセッションを始める")
                        .fontWeight(.semibold)
                        .font(.title3)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [.blue, .blue.opacity(0.8)]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(16)
                .shadow(color: .blue.opacity(0.4), radius: 10, x: 0, y: 5)
            }
            
            Text("セッションデータは保存されました")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Helper Functions
    private func extractMetrics(from s: ServeMetrics) -> [String: Int] {
        [
            "肘": s.score1_elbowAngle,
            "脇": s.score2_armpitAngle,
            "下半身": s.score3_lowerBodyContribution,
            "左手": s.score4_leftHandPosition,
            "体軸": s.score5_bodyAxisTilt,
            "面角": s.score6_racketFaceAngle,
            "トス": s.score7_tossPosition,
            "加速": s.score8_wristwork
        ]
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes)分\(seconds)秒"
    }
    
    // 統計計算
    private var averageScore: Double {
        let total = serves.reduce(0) { $0 + $1.totalScore }
        return Double(total) / Double(serves.count)
    }
    
    private var maxScore: Int {
        serves.map { $0.totalScore }.max() ?? 0
    }
    
    private var minScore: Int {
        serves.map { $0.totalScore }.min() ?? 0
    }
    
    private var standardDeviation: Double {
        let mean = averageScore
        let variance = serves.reduce(0.0) { result, serve in
            let diff = Double(serve.totalScore) - mean
            return result + (diff * diff)
        } / Double(serves.count)
        return sqrt(variance)
    }
    
    private func exportJSON() {
        print("📤 Export JSON")
    }
    
    private func exportCSV() {
        guard let url = DataExporter.exportSessionToCSV(serves: serves) else {
            print("❌ CSV export failed")
            return
        }
        print("✅ CSV exported: \(url)")
    }
    
    private func shareResults() {
        print("📤 Share results")
    }
}

// MARK: - 改善されたスコアカード
struct ScoreCardImproved: View {
    let title: String
    let score: Int
    let color: Color
    let icon: String
    
    var body: some View {
        VStack(spacing: 12) {
            // アイコン
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            
            // タイトル
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            
            // スコア
            Text("\(score)")
                .font(.system(size: 42, weight: .bold))
                .foregroundColor(color)
            
            // ラベル
            Text("点")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(color.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(color.opacity(0.3), lineWidth: 2)
                )
        )
    }
}

// MARK: - 統計カード
struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.2))
                    .frame(width: 44, height: 44)
                
                Image(systemName: icon)
                    .foregroundColor(color)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
            
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.tertiarySystemGroupedBackground))
        )
    }
}

// MARK: - エクスポートボタン
struct ExportButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [color, color.opacity(0.8)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .cornerRadius(12)
        }
    }
}

// MARK: - 改善された凡例アイテム
struct LegendItemImproved: View {
    let color: Color
    let label: String
    let icon: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.caption)
            Text(label)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(color.opacity(0.1))
        )
    }
}

// MARK: - 改善されたスコアテーブル
struct ScoreTableImproved: View {
    let serves: [ServeMetrics]
    
    private let metricNames = [
        "肘角度", "脇角度", "下半身貢献", "左手位置",
        "体軸傾き", "ラケット面角", "トス位置", "ピーク加速"
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack(spacing: 0) {
                Text("項目")
                    .frame(width: 100, alignment: .leading)
                    .font(.caption)
                    .fontWeight(.bold)
                
                ForEach(serves.indices, id: \.self) { i in
                    Text("#\(i + 1)")
                        .frame(width: 55)
                        .font(.caption)
                        .fontWeight(.bold)
                }
                
                Text("変化")
                    .frame(width: 55)
                    .font(.caption)
                    .fontWeight(.bold)
            }
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [.blue, .blue.opacity(0.8)]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(8, corners: [.topLeft, .topRight])
            
            // データ行
            ForEach(Array(metricNames.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 0) {
                    Text(name)
                        .frame(width: 100, alignment: .leading)
                        .font(.caption2)
                        .fontWeight(.medium)
                    
                    ForEach(serves.indices, id: \.self) { idx in
                        let score = getScore(for: name, from: serves[idx])
                        Text("\(score)")
                            .frame(width: 55)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(scoreColor(score))
                    }
                    
                    if let first = serves.first, let last = serves.last {
                        let diff = getScore(for: name, from: last) - getScore(for: name, from: first)
                        HStack(spacing: 4) {
                            Image(systemName: diff >= 0 ? "arrow.up" : "arrow.down")
                                .font(.caption2)
                                .foregroundColor(diff >= 0 ? .green : .red)
                            Text("\(abs(diff))")
                                .font(.caption)
                                .monospacedDigit()
                                .fontWeight(.semibold)
                        }
                        .frame(width: 55)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
                .background(
                    index % 2 == 0 ?
                    Color(UIColor.tertiarySystemGroupedBackground) :
                        Color.clear
                )
            }
        }
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
    
    private func getScore(for name: String, from s: ServeMetrics) -> Int {
        switch name {
        case "肘角度":     return s.score1_elbowAngle
        case "脇角度":     return s.score2_armpitAngle
        case "下半身貢献": return s.score3_lowerBodyContribution
        case "左手位置":   return s.score4_leftHandPosition
        case "体軸傾き":   return s.score5_bodyAxisTilt
        case "ラケット面角": return s.score6_racketFaceAngle
        case "トス位置":   return s.score7_tossPosition
        case "ピーク加速": return s.score8_wristwork
        default: return 0
        }
    }
    
    private func scoreColor(_ score: Int) -> Color {
        if score >= 80 { return .green }
        else if score >= 60 { return .orange }
        else { return .red }
    }
}

// MARK: - 角丸の拡張
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Preview
#Preview {
    let sampleServes = [
        ServeMetrics(
            elbowAngleDeg: 165, armpitAngleDeg: 90, pelvisRisePx: 55,
            leftArmTorsoAngleDeg: 65, leftArmExtensionDeg: 170, bodyAxisDeviationDeg: 8,
            racketFaceYawDeg: 12, racketFacePitchDeg: 8, tossOffsetFromBaselinePx: 5.0,
            wristRotationDeg: 150, tossPositionX: 760.0, tossOffsetFromCenterPx: 120.0,
            score1_elbowAngle: 85, score2_armpitAngle: 80,
            score3_lowerBodyContribution: 75, score4_leftHandPosition: 82,
            score5_bodyAxisTilt: 70, score6_racketFaceAngle: 78, score7_tossPosition: 88,
            score8_wristwork: 72, totalScore: 79, timestamp: Date(), flags: []
        ),
        ServeMetrics(
            elbowAngleDeg: 168, armpitAngleDeg: 92, pelvisRisePx: 65,
            leftArmTorsoAngleDeg: 65, leftArmExtensionDeg: 170, bodyAxisDeviationDeg: 6,
            racketFaceYawDeg: 8, racketFacePitchDeg: 6, tossOffsetFromBaselinePx: 15.0,
            wristRotationDeg: 180, tossPositionX: 640.0, tossOffsetFromCenterPx: 0.0,
            score1_elbowAngle: 92, score2_armpitAngle: 88,
            score3_lowerBodyContribution: 90, score4_leftHandPosition: 84,
            score5_bodyAxisTilt: 78, score6_racketFaceAngle: 86, score7_tossPosition: 92,
            score8_wristwork: 85, totalScore: 87, timestamp: Date().addingTimeInterval(120), flags: []
        )
    ]
    
    SessionSummaryView(serves: sampleServes, onNewSession: { print("New Session") })
}
