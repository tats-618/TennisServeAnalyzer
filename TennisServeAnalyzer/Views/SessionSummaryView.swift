//
//  SessionSummaryView.swift
//  TennisServeAnalyzer
//
//  Created by 島本健生 on 2025/11/06.
//


import SwiftUI

struct SessionSummaryView: View {
    let serves: [ServeMetrics]
    
    private var firstServe: ServeMetrics? { serves.first }
    private var lastServe: ServeMetrics? { serves.last }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // ヘッダー
                Text("セッション完了")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("\(serves.count)本のサーブを記録")
                    .font(.title3)
                    .foregroundColor(.secondary)
                
                Divider()
                
                // スコア比較
                if let first = firstServe, let last = lastServe {
                    ScoreComparisonView(first: first, last: last)
                }
                
                Divider()
                
                // レーダーチャート
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
                
                // エクスポートボタン
                ExportButtonsView(serves: serves)
            }
            .padding()
        }
    }
    
    private func extractMetrics(from serve: ServeMetrics) -> [String: Int] {
        [
            "トス": serve.score1_tossStability,
            "肩傾斜": serve.score2_shoulderPelvisTilt,
            "膝": serve.score3_kneeFlexion,
            "肘": serve.score4_elbowAngle,
            "ラケット": serve.score5_racketDrop,
            "体幹": serve.score6_trunkTiming,
            "タイミング": serve.score7_tossToImpactTiming
        ]
    }
}

struct ScoreComparisonView: View {
    let first: ServeMetrics
    let last: ServeMetrics
    
    private var scoreDiff: Int {
        last.totalScore - first.totalScore
    }
    
    var body: some View {
        HStack(spacing: 32) {
            // 初球
            ScoreCard(title: "初球", score: first.totalScore, color: .pink)
            
            // 矢印
            VStack {
                Image(systemName: scoreDiff >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.largeTitle)
                    .foregroundColor(scoreDiff >= 0 ? .green : .red)
                
                Text("\(scoreDiff >= 0 ? "+" : "")\(scoreDiff)")
                    .font(.headline)
                    .fontWeight(.bold)
            }
            
            // 最後
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
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("\(score)")
                .font(.system(size: 48, weight: .bold))
                .foregroundColor(color)
            
            Text("点")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(width: 120)
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(12)
    }
}

struct ScoreTableView: View {
    let serves: [ServeMetrics]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("詳細スコア")
                .font(.headline)
            
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    // ヘッダー
                    HStack(spacing: 0) {
                        Text("項目")
                            .frame(width: 120, alignment: .leading)
                        
                        ForEach(serves.indices, id: \.self) { index in
                            Text("#\(index + 1)")
                                .frame(width: 60)
                        }
                        
                        Text("変化")
                            .frame(width: 60)
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.1))
                    
                    Divider()
                    
                    // データ行
                    ForEach(metricNames, id: \.self) { name in
                        HStack(spacing: 0) {
                            Text(name)
                                .frame(width: 120, alignment: .leading)
                                .font(.caption)
                            
                            ForEach(serves.indices, id: \.self) { index in
                                let score = getScore(for: name, from: serves[index])
                                Text("\(score)")
                                    .frame(width: 60)
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                            
                            // 変化（最初→最後）
                            if let first = serves.first, let last = serves.last {
                                let diff = getScore(for: name, from: last) - getScore(for: name, from: first)
                                
                                HStack(spacing: 2) {
                                    Image(systemName: diff >= 0 ? "arrow.up" : "arrow.down")
                                        .font(.caption2)
                                        .foregroundColor(diff >= 0 ? .green : .red)
                                    
                                    Text("\(abs(diff))")
                                        .font(.caption)
                                        .monospacedDigit()
                                }
                                .frame(width: 60)
                            }
                        }
                        .padding(.vertical, 4)
                        
                        if name != metricNames.last {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
    
    private let metricNames = [
        "トス安定性",
        "肩骨盤傾斜",
        "膝屈曲",
        "肘角度",
        "ラケット落とし",
        "体幹タイミング",
        "トスインパクト"
    ]
    
    private func getScore(for name: String, from serve: ServeMetrics) -> Int {
        switch name {
        case "トス安定性": return serve.score1_tossStability
        case "肩骨盤傾斜": return serve.score2_shoulderPelvisTilt
        case "膝屈曲": return serve.score3_kneeFlexion
        case "肘角度": return serve.score4_elbowAngle
        case "ラケット落とし": return serve.score5_racketDrop
        case "体幹タイミング": return serve.score6_trunkTiming
        case "トスインパクト": return serve.score7_tossToImpactTiming
        default: return 0
        }
    }
}

struct LegendItem: View {
    let color: Color
    let label: String
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
            
            Text(label)
                .font(.caption)
        }
    }
}

struct ExportButtonsView: View {
    let serves: [ServeMetrics]
    
    var body: some View {
        VStack(spacing: 12) {
            Text("データエクスポート")
                .font(.headline)
            
            HStack(spacing: 12) {
                Button(action: { exportJSON() }) {
                    Label("JSON", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                
                Button(action: { exportCSV() }) {
                    Label("CSV", systemImage: "tablecells")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
        }
    }
    
    private func exportJSON() {
        // DataExporter.exportSessionToJSON() 呼び出し
        print("📤 Exporting JSON...")
    }
    
    private func exportCSV() {
        guard let url = DataExporter.exportSessionToCSV(serves: serves) else {
            print("❌ CSV export failed")
            return
        }
        print("✅ CSV exported: \(url)")
        // UIActivityViewController で共有
    }
}