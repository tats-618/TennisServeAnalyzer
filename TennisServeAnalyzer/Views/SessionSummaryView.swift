//
//  SessionSummaryView.swift
//  TennisServeAnalyzer
//
//  v0.2 metrics (8-items) compatible
//

import SwiftUI

struct SessionSummaryView: View {
    let serves: [ServeMetrics]
    
    private var firstServe: ServeMetrics? { serves.first }
    private var lastServe: ServeMetrics?  { serves.last  }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // ヘッダー
                Text("セッション完了")
                    .font(.largeTitle).fontWeight(.bold)
                
                Text("\(serves.count)本のサーブを記録")
                    .font(.title3).foregroundColor(.secondary)
                
                Divider()
                
                // スコア比較
                if let first = firstServe, let last = lastServe {
                    ScoreComparisonView(first: first, last: last)
                }
                
                Divider()
                
                // レーダーチャート（最後 vs 初球）
                if let first = firstServe, let last = lastServe {
                    VStack(spacing: 16) {
                        Text("パフォーマンス比較")
                            .font(.headline)
                        RadarChartView(
                            metrics: extractMetrics(from: last),
                            referenceMetrics: extractMetrics(from: first)
                        )
                        .frame(height: 300)
                        
                        HStack(spacing: 16) {
                            LegendItem(color: .blue, label: "最後")
                            LegendItem(color: .pink, label: "初球")
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(12)
                }
                
                Divider()
                
                // スコア推移テーブル
                ScoreTableView(serves: serves)
                
                Divider()
                
                // エクスポート
                ExportButtonsView(serves: serves)
            }
            .padding()
        }
    }
    
    /// レーダー用に 8 指標スコアを辞書化
    private func extractMetrics(from s: ServeMetrics) -> [String: Int] {
        [
            "肘": s.score1_elbowAngle,
            "脇": s.score2_armpitAngle,
            "下半身": s.score3_lowerBodyContribution,
            "左手": s.score4_leftHandPosition,
            "体軸": s.score5_bodyAxisTilt,
            "面角": s.score6_racketFaceAngle,
            "トス位置": s.score7_tossPosition,
            "リスト": s.score8_wristwork
        ]
    }
}

// MARK: - スコア比較
struct ScoreComparisonView: View {
    let first: ServeMetrics
    let last: ServeMetrics
    
    private var scoreDiff: Int { last.totalScore - first.totalScore }
    
    var body: some View {
        HStack(spacing: 32) {
            ScoreCard(title: "初球", score: first.totalScore, color: .pink)
            VStack {
                Image(systemName: scoreDiff >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.largeTitle)
                    .foregroundColor(scoreDiff >= 0 ? .green : .red)
                Text("\(scoreDiff >= 0 ? "+" : "")\(scoreDiff)")
                    .font(.headline).fontWeight(.bold)
            }
            ScoreCard(title: "最後", score: last.totalScore, color: .blue)
        }
        .padding()
    }
}

struct ScoreCard: View {
    let title: String
    let score: Int
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text("\(score)")
                .font(.system(size: 48, weight: .bold))
                .foregroundColor(color)
            Text("点").font(.caption).foregroundColor(.secondary)
        }
        .frame(width: 120)
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - スコア推移テーブル（8指標）
struct ScoreTableView: View {
    let serves: [ServeMetrics]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("詳細スコア").font(.headline)
            
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    // ヘッダー
                    HStack(spacing: 0) {
                        Text("項目").frame(width: 120, alignment: .leading)
                        ForEach(serves.indices, id: \.self) { i in
                            Text("#\(i + 1)").frame(width: 60)
                        }
                        Text("変化").frame(width: 60)
                    }
                    .font(.caption).fontWeight(.semibold)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.1))
                    
                    Divider()
                    
                    // 各行
                    ForEach(metricNames, id: \.self) { name in
                        HStack(spacing: 0) {
                            Text(name).frame(width: 120, alignment: .leading).font(.caption)
                            
                            ForEach(serves.indices, id: \.self) { idx in
                                let score = getScore(for: name, from: serves[idx])
                                Text("\(score)")
                                    .frame(width: 60)
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                            
                            if let first = serves.first, let last = serves.last {
                                let diff = getScore(for: name, from: last) - getScore(for: name, from: first)
                                HStack(spacing: 2) {
                                    Image(systemName: diff >= 0 ? "arrow.up" : "arrow.down")
                                        .font(.caption2)
                                        .foregroundColor(diff >= 0 ? .green : .red)
                                    Text("\(abs(diff))").font(.caption).monospacedDigit()
                                }
                                .frame(width: 60)
                            }
                        }
                        .padding(.vertical, 4)
                        
                        if name != metricNames.last { Divider() }
                    }
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
    
    private let metricNames = [
        "肘角度",
        "脇角度",
        "下半身貢献",
        "左手位置",
        "体軸傾き",
        "ラケット面角",
        "トス位置",
        "リストワーク"
    ]
    
    private func getScore(for name: String, from s: ServeMetrics) -> Int {
        switch name {
        case "肘角度":     return s.score1_elbowAngle
        case "脇角度":     return s.score2_armpitAngle
        case "下半身貢献": return s.score3_lowerBodyContribution
        case "左手位置":   return s.score4_leftHandPosition
        case "体軸傾き":   return s.score5_bodyAxisTilt
        case "ラケット面角": return s.score6_racketFaceAngle
        case "トス位置":   return s.score7_tossPosition
        case "リストワーク": return s.score8_wristwork
        default: return 0
        }
    }
}

// MARK: - Legend
struct LegendItem: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(label).font(.caption)
        }
    }
}

// MARK: - Export buttons
struct ExportButtonsView: View {
    let serves: [ServeMetrics]
    var body: some View {
        VStack(spacing: 12) {
            Text("データエクスポート").font(.headline)
            HStack(spacing: 12) {
                Button(action: { exportJSON() }) {
                    Label("JSON", systemImage: "doc.text")
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.blue).foregroundColor(.white)
                        .cornerRadius(10)
                }
                Button(action: { exportCSV() }) {
                    Label("CSV", systemImage: "tablecells")
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.green).foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
        }
    }
    private func exportJSON() {
        // 必要なら個別サーブのJSON出力実装を追加
        print("📤 Export JSON (implement as needed)")
    }
    private func exportCSV() {
        guard let url = DataExporter.exportSessionToCSV(serves: serves) else {
            print("❌ CSV export failed"); return
        }
        print("✅ CSV exported: \(url)")
    }
}

