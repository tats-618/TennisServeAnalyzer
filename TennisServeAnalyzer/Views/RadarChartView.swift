//
//  RadarChartView.swift
//  TennisServeAnalyzer
//
//  🔧 v1.1 — 点と線のずれ修正（sortedKeys統一）
//

import SwiftUI

struct RadarChartView: View {
    let metrics: [String: Int]  // 項目名: スコア（0-100）
    let referenceMetrics: [String: Int]?  // 比較対象（初球など）
    
    private let maxValue: Double = 100.0
    
    // 🔧 修正: キーの順序を固定（すべての描画で同じ順序を使用）
    private var sortedKeys: [String] {
        Array(metrics.keys).sorted()
    }
    
    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = min(geometry.size.width, geometry.size.height) / 2 * 0.8
            
            ZStack {
                // 背景の同心円
                ForEach([20, 40, 60, 80, 100], id: \.self) { value in
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        .frame(width: radius * 2 * CGFloat(value) / 100,
                               height: radius * 2 * CGFloat(value) / 100)
                        .position(center)
                    
                    // 値ラベル
                    Text("\(value)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .position(x: center.x, y: center.y - radius * CGFloat(value) / 100)
                }
                
                // 軸線とラベル
                // 🔧 修正: sortedKeysを使用
                ForEach(Array(sortedKeys.enumerated()), id: \.offset) { index, key in
                    let angle = angleForIndex(index, total: sortedKeys.count)
                    
                    Path { path in
                        path.move(to: center)
                        path.addLine(to: pointOnCircle(center: center, radius: radius, angle: angle))
                    }
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    
                    // ラベル
                    Text(key)
                        .font(.caption)
                        .fontWeight(.medium)
                        .position(labelPosition(center: center, radius: radius * 1.2, angle: angle))
                }
                
                // 参照データ（初球など）
                if let refMetrics = referenceMetrics {
                    radarPath(metrics: refMetrics, center: center, radius: radius)
                        .fill(Color.pink.opacity(0.2))
                    
                    radarPath(metrics: refMetrics, center: center, radius: radius)
                        .stroke(Color.pink, lineWidth: 2)
                    
                    // 🆕 参照データのポイント
                    ForEach(Array(sortedKeys.enumerated()), id: \.offset) { index, key in
                        if let value = refMetrics[key] {
                            let angle = angleForIndex(index, total: sortedKeys.count)
                            let point = pointOnCircle(
                                center: center,
                                radius: radius * CGFloat(Double(value) / maxValue),
                                angle: angle
                            )
                            
                            Circle()
                                .fill(Color.pink)
                                .frame(width: 6, height: 6)
                                .position(point)
                        }
                    }
                }
                
                // 現在のデータ
                radarPath(metrics: metrics, center: center, radius: radius)
                    .fill(Color.blue.opacity(0.2))
                
                radarPath(metrics: metrics, center: center, radius: radius)
                    .stroke(Color.blue, lineWidth: 3)
                
                // データポイント
                // 🔧 修正: sortedKeysを使用して、パスと同じ順序で描画
                ForEach(Array(sortedKeys.enumerated()), id: \.offset) { index, key in
                    if let value = metrics[key] {
                        let angle = angleForIndex(index, total: sortedKeys.count)
                        let point = pointOnCircle(
                            center: center,
                            radius: radius * CGFloat(Double(value) / maxValue),
                            angle: angle
                        )
                        
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 8, height: 8)
                            .position(point)
                    }
                }
            }
        }
    }
    
    private func radarPath(metrics: [String: Int], center: CGPoint, radius: CGFloat) -> Path {
        Path { path in
            // 🔧 修正: sortedKeysを使用
            let keys = Array(metrics.keys).sorted()
            
            for (index, key) in keys.enumerated() {
                let value = Double(metrics[key] ?? 0)
                let angle = angleForIndex(index, total: keys.count)
                let point = pointOnCircle(
                    center: center,
                    radius: radius * CGFloat(value / maxValue),
                    angle: angle
                )
                
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            
            path.closeSubpath()
        }
    }
    
    private func angleForIndex(_ index: Int, total: Int) -> Double {
        let angleStep = 2 * .pi / Double(total)
        return angleStep * Double(index) - .pi / 2  // -90度から開始
    }
    
    private func pointOnCircle(center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        CGPoint(
            x: center.x + radius * CGFloat(cos(angle)),
            y: center.y + radius * CGFloat(sin(angle))
        )
    }
    
    private func labelPosition(center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        pointOnCircle(center: center, radius: radius, angle: angle)
    }
}

#Preview {
    RadarChartView(
        metrics: [
            "トス": 78,
            "肩傾斜": 65,
            "膝屈曲": 82,
            "肘角度": 90,
            "ラケット": 80,
            "体幹": 58,
            "タイミング": 74
        ],
        referenceMetrics: [
            "トス": 65,
            "肩傾斜": 70,
            "膝屈曲": 75,
            "肘角度": 85,
            "ラケット": 70,
            "体幹": 65,
            "タイミング": 80
        ]
    )
    .frame(width: 300, height: 300)
    .padding()
}
