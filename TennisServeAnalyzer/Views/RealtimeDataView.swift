//
//  RealtimeDataView.swift
//  TennisServeAnalyzer
//
//  Created by 島本健生 on 2025/05/28.
//

import SwiftUI

struct iOSRealtimeDataView: View {
    let data: ServeData?
    let count: Int
    
    var body: some View {
        VStack(spacing: 16) {
            // ヘッダー
            HStack {
                Text("リアルタイムデータ")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    
                    Text("サンプル数: \(count)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }
            }
            
            if let data = data {
                // センサーデータ表示
                VStack(spacing: 12) {
                    // 加速度データ
                    SensorDataCard(
                        title: "加速度",
                        icon: "speedometer",
                        x: data.acceleration.x,
                        y: data.acceleration.y,
                        z: data.acceleration.z,
                        unit: "g",
                        color: .blue
                    )
                    
                    // ジャイロスコープデータ
                    SensorDataCard(
                        title: "角速度",
                        icon: "gyroscope",
                        x: data.gyroscope.x,
                        y: data.gyroscope.y,
                        z: data.gyroscope.z,
                        unit: "rad/s",
                        color: .green
                    )
                }
            } else {
                Text("データ待機中...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.05))
        )
    }
}

struct SensorDataCard: View {
    let title: String
    let icon: String
    let x: Double
    let y: Double
    let z: Double
    let unit: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 12) {
            // カードヘッダー
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundColor(color)
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                Text(unit)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color.opacity(0.1))
                    )
            }
            
            // 3軸データ表示
            HStack(spacing: 20) {
                AxisValueView(label: "X軸", value: x, color: color)
                AxisValueView(label: "Y軸", value: y, color: color)
                AxisValueView(label: "Z軸", value: z, color: color)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.05))
        )
    }
}

struct AxisValueView: View {
    let label: String
    let value: Double
    let color: Color
    
    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(color)
            
            Text(String(format: "%.3f", value))
                .font(.title3)
                .fontWeight(.bold)
                .monospacedDigit()
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    let sampleData = ServeData(
        timestamp: Date(),
        acceleration: (x: 1.234, y: -0.567, z: 9.812),
        gyroscope: (x: 0.123, y: -0.456, z: 1.789)
    )
    
    return iOSRealtimeDataView(data: sampleData, count: 147)
        .padding()
}
