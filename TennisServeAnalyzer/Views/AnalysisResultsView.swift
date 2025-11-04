//
//  AnalysisResultsView.swift
//  TennisServeAnalyzer
//
//  Created by 島本健生 on 2025/05/28.
//
// BEGIN PATCH - フラグ表示部分のみ更新
// iOSDataQualityView を拡張

// BEGIN PATCH - iOS用完全版
//
//  AnalysisResultsView.swift
//  TennisServeAnalyzer
//
//  Created by 島本健生 on 2025/05/28.
//

import SwiftUI

struct iOSAnalysisResultView: View {
    let analysis: ServeAnalysis
    let dataQuality: (isValid: Bool, message: String)
    let flags: [String]  // v0.2: 追加パラメータ
    
    var body: some View {
        VStack(spacing: 16) {
            // ヘッダー
            HStack {
                Text("サーブ解析結果")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
            }
            
            // データ品質インジケーター（v0.2: flags を渡す）
            iOSDataQualityView(quality: dataQuality, flags: flags)
            
            // 主要指標（大きな表示）
            iOSMainMetricsView(analysis: analysis)
            
            // 詳細指標
            iOSDetailedMetricsView(analysis: analysis)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.05))
        )
    }
}

struct iOSDataQualityView: View {
    let quality: (isValid: Bool, message: String)
    let flags: [String]  // v0.2: 外部から渡されるフラグ
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: quality.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(quality.isValid ? .green : .orange)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(quality.isValid ? "データ品質: 良好" : "データ品質: 警告")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Text(quality.message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // v0.2: Flags タグ表示
            if !flags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(flags, id: \.self) { flag in
                            FlagBadge(flag: flag)
                        }
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((quality.isValid ? Color.green : Color.orange).opacity(0.1))
        )
    }
}

struct FlagBadge: View {
    let flag: String
    
    var body: some View {
        Text(flagDisplayText)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(flagColor.opacity(0.2))
            )
            .foregroundColor(flagColor)
    }
    
    private var flagDisplayText: String {
        switch flag {
        case "imu_below_100hz": return "低Hz"
        case "delayed_batch": return "遅延"
        case "thermal_downscale": return "高温"
        case "resampled_100_149hz": return "補間済"
        case "recovered_from_file": return "補完済"
        default: return flag
        }
    }
    
    private var flagColor: Color {
        if flag.contains("below") || flag.contains("invalid") {
            return .red
        } else if flag.contains("delayed") || flag.contains("thermal") {
            return .orange
        } else if flag.contains("resampled") || flag.contains("recovered") {
            return .blue
        } else {
            return .gray
        }
    }
}

struct iOSMainMetricsView: View {
    let analysis: ServeAnalysis
    
    var body: some View {
        VStack(spacing: 12) {
            Text("主要パフォーマンス指標")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                iOSMetricCard(
                    title: "スイング速度",
                    value: String(format: "%.1f", analysis.estimatedSwingSpeed),
                    unit: "m/s",
                    icon: "speedometer",
                    color: .blue
                )
                
                iOSMetricCard(
                    title: "最大加速度",
                    value: String(format: "%.1f", analysis.maxAcceleration),
                    unit: "g",
                    icon: "waveform.path.ecg",
                    color: .green
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.1))
        )
    }
}

struct iOSDetailedMetricsView: View {
    let analysis: ServeAnalysis
    
    var body: some View {
        VStack(spacing: 12) {
            Text("詳細解析データ")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            
            VStack(spacing: 8) {
                iOSDetailRow(
                    icon: "clock",
                    label: "持続時間",
                    value: String(format: "%.2f", analysis.duration),
                    unit: "秒",
                    color: .purple
                )
                
                iOSDetailRow(
                    icon: "gyroscope",
                    label: "最大角速度",
                    value: String(format: "%.2f", analysis.maxAngularVelocity),
                    unit: "rad/s",
                    color: .orange
                )
                
                iOSDetailRow(
                    icon: "calendar.circle",
                    label: "記録時刻",
                    value: formatTime(analysis.recordedAt),
                    unit: "",
                    color: .gray
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.05))
        )
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

struct iOSMetricCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.title2)
                
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(color)
                        .monospacedDigit()
                    
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .frame(height: 100)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.1))
        )
    }
}

struct iOSDetailRow: View {
    let icon: String
    let label: String
    let value: String
    let unit: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)
            
            Text(label)
                .font(.subheadline)
                .foregroundColor(.primary)
            
            Spacer()
            
            HStack(spacing: 4) {
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundColor(.primary)
                
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    let sampleAnalysis = ServeAnalysis(
        maxAcceleration: 15.3,
        maxAngularVelocity: 8.7,
        estimatedSwingSpeed: 25.4,
        duration: 3.8,
        recordedAt: Date()
    )
    
    let sampleQuality = (isValid: true, message: "データ品質OK（補間済み: 142.3Hz → 200Hz）")
    let sampleFlags = ["resampled_100_149hz", "delayed_batch"]
    
    return iOSAnalysisResultView(
        analysis: sampleAnalysis,
        dataQuality: sampleQuality,
        flags: sampleFlags
    )
    .padding()
}
// END PATCH
