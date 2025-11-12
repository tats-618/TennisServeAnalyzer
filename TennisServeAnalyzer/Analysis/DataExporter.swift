//
//  DataExporter.swift
//  TennisServeAnalyzer
//
//  Data export system for research analysis (v0.2 metrics)
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

// MARK: - Complete Serve Record (v0.2)
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
        let wristRotationDeg: Double
        let racketFaceYawDeg: Double
        let racketFacePitchDeg: Double
        let effectiveHz: Double
    }
    let imu: IMUData

    struct VideoData: Codable {
        struct TrophyPose: Codable {
            let elbowAngleDeg: Double
            let armpitAngleDeg: Double
            let leftArmTorsoAngleDeg: Double
            let leftArmExtensionDeg: Double
        }
        let trophyPose: TrophyPose

        struct ImpactPose: Codable {
            let bodyAxisDeviationDeg: Double
        }
        let impactPose: ImpactPose

        struct Toss: Codable {
            let forwardDistanceM: Double
        }
        let toss: Toss
    }
    let video: VideoData

    struct Metrics: Codable {
        let metric1ElbowAngle: Int
        let metric2ArmpitAngle: Int
        let metric3LowerBodyContribution: Int
        let metric4LeftHandPosition: Int
        let metric5BodyAxisTilt: Int
        let metric6RacketFaceAngle: Int
        let metric7TossPosition: Int
        let metric8Wristwork: Int
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

        // ID
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let dateString = formatter.string(from: serveMetrics.timestamp)
        let serveID = "\(dateString)_serve_\(UUID().uuidString.prefix(8))"

        // Times
        let tTrophyMs = (trophyEvent?.timestamp ?? 0.0) * 1000.0
        let tImpactMs = Double(impactEvent?.monotonicMs ?? 0)
        let latencyS  = max(0.0, (tImpactMs - tTrophyMs) / 1000.0)

        // Build complete record
        let record = CompleteServeRecord(
            id: serveID,
            syncQuality: syncQuality,
            times: CompleteServeRecord.Times(
                tTrophyMs: tTrophyMs,
                tImpactMs: tImpactMs,
                latencyS: latencyS
            ),
            imu: CompleteServeRecord.IMUData(
                omegaPeakDps: (impactEvent?.peakAngularVelocity ?? 0.0) * 180.0 / .pi,
                wristRotationDeg: serveMetrics.wristRotationDeg,
                racketFaceYawDeg: serveMetrics.racketFaceYawDeg,
                racketFacePitchDeg: serveMetrics.racketFacePitchDeg,
                effectiveHz: effectiveHz
            ),
            video: CompleteServeRecord.VideoData(
                trophyPose: CompleteServeRecord.VideoData.TrophyPose(
                    elbowAngleDeg: serveMetrics.elbowAngleDeg,
                    armpitAngleDeg: serveMetrics.armpitAngleDeg,
                    leftArmTorsoAngleDeg: serveMetrics.leftArmTorsoAngleDeg,
                    leftArmExtensionDeg: serveMetrics.leftArmExtensionDeg
                ),
                impactPose: CompleteServeRecord.VideoData.ImpactPose(
                    bodyAxisDeviationDeg: serveMetrics.bodyAxisDeviationDeg
                ),
                toss: CompleteServeRecord.VideoData.Toss(
                    forwardDistanceM: serveMetrics.tossForwardDistanceM
                )
            ),
            metrics: CompleteServeRecord.Metrics(
                metric1ElbowAngle: serveMetrics.score1_elbowAngle,
                metric2ArmpitAngle: serveMetrics.score2_armpitAngle,
                metric3LowerBodyContribution: serveMetrics.score3_lowerBodyContribution,
                metric4LeftHandPosition: serveMetrics.score4_leftHandPosition,
                metric5BodyAxisTilt: serveMetrics.score5_bodyAxisTilt,
                metric6RacketFaceAngle: serveMetrics.score6_racketFaceAngle,
                metric7TossPosition: serveMetrics.score7_tossPosition,
                metric8Wristwork: serveMetrics.score8_wristwork,
                totalScore: serveMetrics.totalScore
            ),
            calibration: calibrationResult.map {
                CompleteServeRecord.Calibration(
                    rFrameQuality: Double($0.quality),
                    gravityAlignmentErrorDeg: $0.gravityAlignmentError
                )
            },
            flags: serveMetrics.flags
        )

        // Encode to JSON
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(record)

            let filename = "serve_\(serveID).json"
            return saveToFile(data: jsonData, filename: filename)
        } catch {
            print("❌ Failed to encode JSON: \(error)")
            return nil
        }
    }

    // MARK: - Export Session Summary (CSV, v0.2)
    static func exportSessionToCSV(serves: [ServeMetrics]) -> URL? {
        var csv = ""
        csv += "swing_id,timestamp,total_score,"
        csv += "elbow_deg,armpit_deg,pelvis_rise_m,left_torso_deg,left_ext_deg,"
        csv += "body_axis_delta_deg,rface_yaw_deg,rface_pitch_deg,toss_forward_m,wrist_deg,"
        csv += "score1_elbow,score2_armpit,score3_lower,score4_left,score5_axis,score6_rface,score7_toss,score8_wrist,"
        csv += "flags\n"

        let iso = ISO8601DateFormatter()

        for (idx, s) in serves.enumerated() {
            let ts = iso.string(from: s.timestamp)
            let row: [String] = [
                "serve_\(idx + 1)",
                ts,
                "\(s.totalScore)",
                String(format: "%.1f", s.elbowAngleDeg),
                String(format: "%.1f", s.armpitAngleDeg),
                String(format: "%.3f", s.pelvisRisePx),
                String(format: "%.1f", s.leftArmTorsoAngleDeg),
                String(format: "%.1f", s.leftArmExtensionDeg),
                String(format: "%.1f", s.bodyAxisDeviationDeg),
                String(format: "%.1f", s.racketFaceYawDeg),
                String(format: "%.1f", s.racketFacePitchDeg),
                String(format: "%.3f", s.tossForwardDistanceM),
                String(format: "%.0f", s.wristRotationDeg),
                "\(s.score1_elbowAngle)",
                "\(s.score2_armpitAngle)",
                "\(s.score3_lowerBodyContribution)",
                "\(s.score4_leftHandPosition)",
                "\(s.score5_bodyAxisTilt)",
                "\(s.score6_racketFaceAngle)",
                "\(s.score7_tossPosition)",
                "\(s.score8_wristwork)",
                "\"\(s.flags.joined(separator: ";"))\""
            ]
            csv += row.joined(separator: ",") + "\n"
        }

        let filename = "session_\(Date().timeIntervalSince1970).csv"
        guard let data = csv.data(using: .utf8) else { return nil }
        return saveToFile(data: data, filename: filename)
    }

    // MARK: - Export Raw Logs (unchanged)
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
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        viewController.present(activityVC, animated: true)
    }

    // MARK: - Batch Export
    static func exportFullSession(
        serves: [ServeMetrics],
        imuSamples: [ServeSample],
        poseData: [PoseData]
    ) -> [URL] {
        var urls: [URL] = []
        if let csvURL = exportSessionToCSV(serves: serves) { urls.append(csvURL) }
        if let imuURL = exportRawIMU(samples: imuSamples) { urls.append(imuURL) }
        if let poseURL = exportRawPose(poses: poseData) { urls.append(poseURL) }
        print("✅ Batch export complete: \(urls.count) files")
        return urls
    }
}

