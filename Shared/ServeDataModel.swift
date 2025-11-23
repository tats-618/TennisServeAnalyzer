//
//  ServeDataModel.swift
//  TennisServeAnalyzer (iOS & Watch)
//
//  Shared data models for both targets
//

import Foundation
import CoreGraphics // CGPoint を使用するため追加

// MARK: - Ball Apex Result (BallTracker.swift から移動)
public struct BallApex: Codable {
    public let timestamp: Double
    public let position: CGPoint
    public let height: CGFloat
    public let confidence: Float
}

// 個別のセンサーデータを表す構造体
public struct ServeData {
    public let timestamp: Date
    public let acceleration: (x: Double, y: Double, z: Double)
    public let gyroscope: (x: Double, y: Double, z: Double)
    
    public init(timestamp: Date, acceleration: (x: Double, y: Double, z: Double), gyroscope: (x: Double, y: Double, z: Double)) {
        self.timestamp = timestamp
        self.acceleration = acceleration
        self.gyroscope = gyroscope
    }
}

// v0.2: 1サンプル単位の詳細データ（JSON/CSV 出力用）
public struct ServeSample: Codable, Identifiable {
    public let id: UUID
    public let monotonic_ms: Int64
    public let wallclock_iso: String
    public let ax: Double
    public let ay: Double
    public let az: Double
    public let gx: Double
    public let gy: Double
    public let gz: Double
    
    public init(timestamp: Date, monotonicMs: Int64, acceleration: (x: Double, y: Double, z: Double), gyroscope: (x: Double, y: Double, z: Double)) {
        self.id = UUID()
        self.monotonic_ms = monotonicMs
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.wallclock_iso = formatter.string(from: timestamp)
        
        self.ax = acceleration.x
        self.ay = acceleration.y
        self.az = acceleration.z
        self.gx = gyroscope.x
        self.gy = gyroscope.y
        self.gz = gyroscope.z
    }
}

// サーブ解析結果を表す構造体
public struct ServeAnalysis: Codable {
    public let maxAcceleration: Double
    public let maxAngularVelocity: Double
    public let estimatedSwingSpeed: Double
    public let duration: TimeInterval
    public let recordedAt: Date
    
    // ✅ 追加: センサーフュージョン用データ
    public let impactTimestamp: TimeInterval?
    public let impactRacketYaw: Double?
    public let impactRacketPitch: Double?
    public let swingPeakPositionR: Double?  // 追加
    
    public init(
        maxAcceleration: Double,
        maxAngularVelocity: Double,
        estimatedSwingSpeed: Double,
        duration: TimeInterval,
        recordedAt: Date,
        // ✅ 追加引数（デフォルト値付き）
        impactTimestamp: TimeInterval? = nil,
        impactRacketYaw: Double? = nil,
        impactRacketPitch: Double? = nil,
        swingPeakPositionR: Double? = nil
    ) {
        self.maxAcceleration = maxAcceleration
        self.maxAngularVelocity = maxAngularVelocity
        self.estimatedSwingSpeed = estimatedSwingSpeed
        self.duration = duration
        self.recordedAt = recordedAt
        
        self.impactTimestamp = impactTimestamp
        self.impactRacketYaw = impactRacketYaw
        self.impactRacketPitch = impactRacketPitch
        self.swingPeakPositionR = swingPeakPositionR
    }
}

// v0.2: 研究ログ用の拡張解析結果
public struct ServeAnalysisV02: Codable {
    public let schema_version: String
    public let wallclock_iso: String
    public let monotonic_ms: Int64
    public let maxAcceleration: Double
    public let maxAngularVelocity: Double
    public let estimatedSwingSpeed: Double
    public let duration: Double
    public let flags: [String]
    
    public init(schema_version: String, wallclock_iso: String, monotonic_ms: Int64, maxAcceleration: Double, maxAngularVelocity: Double, estimatedSwingSpeed: Double, duration: Double, flags: [String]) {
        self.schema_version = schema_version
        self.wallclock_iso = wallclock_iso
        self.monotonic_ms = monotonic_ms
        self.maxAcceleration = maxAcceleration
        self.maxAngularVelocity = maxAngularVelocity
        self.estimatedSwingSpeed = estimatedSwingSpeed
        self.duration = duration
        self.flags = flags
    }
    
    // 既存 ServeAnalysis への変換
    public func toServeAnalysis() -> ServeAnalysis {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: wallclock_iso) ?? Date()
        
        return ServeAnalysis(
            maxAcceleration: maxAcceleration,
            maxAngularVelocity: maxAngularVelocity,
            estimatedSwingSpeed: estimatedSwingSpeed,
            duration: duration,
            recordedAt: date
        )
    }
}

// v0.2: セッション全体のログ構造
public struct ServeSessionLog: Codable {
    public let schema_version: String
    public let samples: [ServeSample]
    public let analysis: ServeAnalysisV02
    
    public init(schema_version: String, samples: [ServeSample], analysis: ServeAnalysisV02) {
        self.schema_version = schema_version
        self.samples = samples
        self.analysis = analysis
    }
}

// データ収集の状態を表す列挙型
public enum DataCollectionState: Equatable {
    case idle
    case collecting
    case completed
    case error(String)
    
    public static func == (lhs: DataCollectionState, rhs: DataCollectionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.collecting, .collecting),
             (.completed, .completed):
            return true
        case (.error(let lhsMessage), .error(let rhsMessage)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }
}
