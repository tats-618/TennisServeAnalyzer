//
//  DataExporter.swift
//  TennisServeAnalyzer
//
//  Created by 島本健生 on 2025/10/28.
//

//
//  DataExporter.swift
//  TennisServeAnalyzer
//
//  Data export system for research analysis
//  - JSON (single serve)
//  - CSV (session summary)
//  - Raw logs (IMU + Video landmarks)
//

import Foundation
import UIKit

// MARK: - Export Format
enum ExportFormat {
    case json
    case csv
    case rawLog
}

// MARK: - Complete Serve Record
struct CompleteServeRecord: Codable {
    let id: String
    let syncQuality: Double
    
    struct Times: Codable {
        let tTrophyMs: Double
        let tImpactMs: Double
        let latencyS: Double
    }
    let times: Times
    
    struct IMUData: Codable {
        let omegaPeakDps: Double
        let racketDropDeg: Double
        let effectiveHz: Double
    }
    let imu: IMUData
    
    struct VideoData: Codable {
        struct TrophyPose: Codable {
            let shoulderPelvisTiltDeg: Double
            let kneeFlexionDeg: Double
            let elbowAngleDeg: Double
        }
        let trophyPose: TrophyPose
        
        struct Toss: Codable {
            let apexHeightNorm: Double
            let stabilityCV: Double
        }
        let toss: Toss
    }
    let video: VideoData
    
    struct Metrics: Codable {
        let metric1TossStability: Int
        let metric2ShoulderPelvisTilt: Int
        let metric3KneeFlexion: Int
        let metric4ElbowAngle: Int
        let metric5RacketDrop: Int
        let metric6TrunkTiming: Int
        let metric7TossToImpactTiming: Int
        let totalScore: Int
    }
    let metrics: Metrics
    
    struct Calibration: Codable {
        let rFrameQuality: Double
        let gravityAlignmentErrorDeg: Double
    }
    let calibration: Calibration?
    
    let flags: [String]
}

// MARK: - Data Exporter
class DataExporter {
    
    // MARK: - Export Single Serve (JSON)
    static func exportServeToJSON(
        serveMetrics: ServeMetrics,
        trophyEvent: TrophyPoseEvent?,
        impactEvent: ImpactEvent?,
        calibrationResult: CalibrationResult?,
        effectiveHz: Double,
        syncQuality: Double = 1.0
    ) -> URL? {
        
        // Generate unique ID
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let dateString = formatter.string(from: serveMetrics.timestamp)
        
        let serveID = "\(dateString)_serve_\(UUID().uuidString.prefix(8))"
        
        // Build complete record
        let record = CompleteServeRecord(
            id: serveID,
            syncQuality: syncQuality,
            times: CompleteServeRecord.Times(
                tTrophyMs: (trophyEvent?.timestamp ?? 0.0) * 1000,
                tImpactMs: Double(impactEvent?.monotonicMs ?? 0),
                latencyS: serveMetrics.tossToImpactMs / 1000.0
            ),
            imu: CompleteServeRecord.IMUData(
                omegaPeakDps: (impactEvent?.peakAngularVelocity ?? 0.0) * 180.0 / .pi,
                racketDropDeg: serveMetrics.racketDropDeg,
                effectiveHz: effectiveHz
            ),
            video: CompleteServeRecord.VideoData(
                trophyPose: CompleteServeRecord.VideoData.TrophyPose(
                    shoulderPelvisTiltDeg: serveMetrics.shoulderPelvisTiltDeg,
                    kneeFlexionDeg: serveMetrics.kneeFlexionDeg,
                    elbowAngleDeg: serveMetrics.elbowAngleDeg
                ),
                toss: CompleteServeRecord.VideoData.Toss(
                    apexHeightNorm: 0.72,  // Placeholder
                    stabilityCV: serveMetrics.tossStabilityCV
                )
            ),
            metrics: CompleteServeRecord.Metrics(
                metric1TossStability: serveMetrics.score1_tossStability,
                metric2ShoulderPelvisTilt: serveMetrics.score2_shoulderPelvisTilt,
                metric3KneeFlexion: serveMetrics.score3_kneeFlexion,
                metric4ElbowAngle: serveMetrics.score4_elbowAngle,
                metric5RacketDrop: serveMetrics.score5_racketDrop,
                metric6TrunkTiming: serveMetrics.score6_trunkTiming,
                metric7TossToImpactTiming: serveMetrics.score7_tossToImpactTiming,
                totalScore: serveMetrics.totalScore
            ),
            calibration: calibrationResult != nil ? CompleteServeRecord.Calibration(
                rFrameQuality: Double(calibrationResult!.quality),
                gravityAlignmentErrorDeg: calibrationResult!.gravityAlignmentError
            ) : nil,
            flags: serveMetrics.flags
        )
        
        // Encode to JSON
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(record)
            
            // Save to file
            let filename = "serve_\(serveID).json"
            return saveToFile(data: jsonData, filename: filename)
            
        } catch {
            print("❌ Failed to encode JSON: \(error)")
            return nil
        }
    }
    
    // MARK: - Export Session Summary (CSV)
    static func exportSessionToCSV(serves: [ServeMetrics]) -> URL? {
        var csvString = "swing_id,timestamp,total_score,"
        csvString += "toss_stability,shoulder_tilt,knee_flexion,elbow_angle,"
        csvString += "racket_drop,trunk_timing,toss_impact_timing,"
        csvString += "flags\n"
        
        for (index, serve) in serves.enumerated() {
            let formatter = ISO8601DateFormatter()
            let timestamp = formatter.string(from: serve.timestamp)
            
            let row = [
                "serve_\(index + 1)",
                timestamp,
                "\(serve.totalScore)",
                "\(serve.score1_tossStability)",
                "\(serve.score2_shoulderPelvisTilt)",
                "\(serve.score3_kneeFlexion)",
                "\(serve.score4_elbowAngle)",
                "\(serve.score5_racketDrop)",
                "\(serve.score6_trunkTiming)",
                "\(serve.score7_tossToImpactTiming)",
                "\"\(serve.flags.joined(separator: ";"))\""
            ]
            
            csvString += row.joined(separator: ",") + "\n"
        }
        
        // Save to file
        let filename = "session_\(Date().timeIntervalSince1970).csv"
        guard let data = csvString.data(using: .utf8) else { return nil }
        
        return saveToFile(data: data, filename: filename)
    }
    
    // MARK: - Export Raw Logs
    static func exportRawIMU(samples: [ServeSample]) -> URL? {
        var csvString = "monotonic_ms,wallclock_iso,ax,ay,az,gx,gy,gz\n"
        
        for sample in samples {
            let row = [
                "\(sample.monotonic_ms)",
                sample.wallclock_iso,
                String(format: "%.6f", sample.ax),
                String(format: "%.6f", sample.ay),
                String(format: "%.6f", sample.az),
                String(format: "%.6f", sample.gx),
                String(format: "%.6f", sample.gy),
                String(format: "%.6f", sample.gz)
            ]
            
            csvString += row.joined(separator: ",") + "\n"
        }
        
        let filename = "raw_imu_\(Date().timeIntervalSince1970).csv"
        guard let data = csvString.data(using: .utf8) else { return nil }
        
        return saveToFile(data: data, filename: filename)
    }
    
    static func exportRawPose(poses: [PoseData]) -> URL? {
        var csvString = "timestamp,joint,x,y,confidence\n"
        
        for pose in poses {
            for (joint, point) in pose.joints {
                let confidence = pose.confidences[joint] ?? 0.0
                
                let row = [
                    String(format: "%.6f", pose.timestamp),
                    joint.rawValue,
                    String(format: "%.2f", point.x),
                    String(format: "%.2f", point.y),
                    String(format: "%.3f", confidence)
                ]
                
                csvString += row.joined(separator: ",") + "\n"
            }
        }
        
        let filename = "raw_pose_\(Date().timeIntervalSince1970).csv"
        guard let data = csvString.data(using: .utf8) else { return nil }
        
        return saveToFile(data: data, filename: filename)
    }
    
    // MARK: - File Management
    private static func saveToFile(data: Data, filename: String) -> URL? {
        guard let documentsDirectory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            print("❌ Cannot access documents directory")
            return nil
        }
        
        let fileURL = documentsDirectory.appendingPathComponent(filename)
        
        do {
            try data.write(to: fileURL)
            print("✅ Exported: \(fileURL.path)")
            return fileURL
        } catch {
            print("❌ Failed to write file: \(error)")
            return nil
        }
    }
    
    // MARK: - Share/Export
    static func shareFile(url: URL, from viewController: UIViewController) {
        let activityVC = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        
        viewController.present(activityVC, animated: true)
    }
    
    // MARK: - Batch Export
    static func exportFullSession(
        serves: [ServeMetrics],
        imuSamples: [ServeSample],
        poseData: [PoseData]
    ) -> [URL] {
        var urls: [URL] = []
        
        // Session summary CSV
        if let csvURL = exportSessionToCSV(serves: serves) {
            urls.append(csvURL)
        }
        
        // Raw IMU data
        if let imuURL = exportRawIMU(samples: imuSamples) {
            urls.append(imuURL)
        }
        
        // Raw pose data
        if let poseURL = exportRawPose(poses: poseData) {
            urls.append(poseURL)
        }
        
        print("✅ Batch export complete: \(urls.count) files")
        return urls
    }
}
