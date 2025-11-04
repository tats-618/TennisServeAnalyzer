//
//  SamplingUtils.swift
//  TennisServeAnalyzer
//
//  Created by 島本健生 on 2025/10/21.
//


import Foundation

struct SamplingUtils {
    
    // 実効サンプリングレートを推定（移動ウィンドウ）
    static func estimateEffectiveHz(samples: [ServeSample]) -> Double {
        guard samples.count >= 2 else { return 0.0 }
        
        var intervals: [Double] = []
        for i in 1..<samples.count {
            let dt = Double(samples[i].monotonic_ms - samples[i-1].monotonic_ms) / 1000.0
            if dt > 0 {
                intervals.append(dt)
            }
        }
        
        guard !intervals.isEmpty else { return 0.0 }
        let avgInterval = intervals.reduce(0.0, +) / Double(intervals.count)
        return avgInterval > 0 ? 1.0 / avgInterval : 0.0
    }
    
    // 線形補間で200Hz相当に再サンプリング
    static func resampleTo200Hz(samples: [ServeSample]) -> [ServeSample] {
        guard samples.count >= 2 else { return samples }
        
        let targetInterval: Int64 = 5  // 5ms = 200Hz
        var resampled: [ServeSample] = []
        
        guard let firstMs = samples.first?.monotonic_ms,
              let lastMs = samples.last?.monotonic_ms else { return samples }
        
        var currentMs = firstMs
        var idx = 0
        
        while currentMs <= lastMs {
            // 現在の時刻を挟む2サンプルを探す
            while idx < samples.count - 1 && samples[idx + 1].monotonic_ms < currentMs {
                idx += 1
            }
            
            if idx >= samples.count - 1 {
                break
            }
            
            let s0 = samples[idx]
            let s1 = samples[idx + 1]
            
            let dt = Double(s1.monotonic_ms - s0.monotonic_ms)
            if dt > 0 {
                let t = Double(currentMs - s0.monotonic_ms) / dt
                
                let interpolated = ServeSample(
                    timestamp: Date(timeIntervalSince1970: Double(currentMs) / 1000.0),
                    monotonicMs: currentMs,
                    acceleration: (
                        x: lerp(s0.ax, s1.ax, t),
                        y: lerp(s0.ay, s1.ay, t),
                        z: lerp(s0.az, s1.az, t)
                    ),
                    gyroscope: (
                        x: lerp(s0.gx, s1.gx, t),
                        y: lerp(s0.gy, s1.gy, t),
                        z: lerp(s0.gz, s1.gz, t)
                    )
                )
                resampled.append(interpolated)
            }
            
            currentMs += targetInterval
        }
        
        return resampled.isEmpty ? samples : resampled
    }
    
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        return a + (b - a) * t
    }
}
