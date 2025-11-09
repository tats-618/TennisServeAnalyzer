//
//  PoseDetector.swift
//  TennisServeAnalyzer
//
//  Created by å³¶æœ¬å¥ç”Ÿ on 2025/10/28.
//

//
//  PoseDetector.swift
//  TennisServeAnalyzer
//
//  Human body pose detection using Vision framework
//  - VNDetectHumanBodyPoseRequest
//  - Coordinate transformation (Vision normalized -> Screen)
//  - Confidence filtering
//  - Joint angle calculation
//

import Vision
import CoreMedia
import UIKit
import AVFoundation

// MARK: - Joint Names (Vision)
enum BodyJoint: String, CaseIterable {
    // Torso
    case neck = "neck"
    case nose = "nose"
    
    // Right side
    case rightShoulder = "right_shoulder"
    case rightElbow = "right_elbow"
    case rightWrist = "right_wrist"
    case rightHip = "right_hip"
    case rightKnee = "right_knee"
    case rightAnkle = "right_ankle"
    
    // Left side
    case leftShoulder = "left_shoulder"
    case leftElbow = "left_elbow"
    case leftWrist = "left_wrist"
    case leftHip = "left_hip"
    case leftKnee = "left_knee"
    case leftAnkle = "left_ankle"
    
    // Center
    case root = "root"  // Pelvis center
}

// MARK: - Pose Data Structure
struct PoseData {
    let timestamp: Double
    let joints: [BodyJoint: CGPoint]  // Screen coordinates (origin: top-left)
    let confidences: [BodyJoint: Float]
    let imageSize: CGSize
    
    // Quality metrics
    var averageConfidence: Float {
        guard !confidences.isEmpty else { return 0.0 }
        return confidences.values.reduce(0, +) / Float(confidences.count)
    }
    
    var isValid: Bool {
        return averageConfidence > 0.3 && joints.count >= 10
    }
}

// MARK: - Pose Detector
class PoseDetector {
    // MARK: Properties
    private let poseRequest: VNDetectHumanBodyPoseRequest
    
    // Configuration
    private let minimumConfidence: Float = 0.3
    
    // MARK: - Initialization
    init() {
        poseRequest = VNDetectHumanBodyPoseRequest()
        poseRequest.revision = VNDetectHumanBodyPoseRequestRevision1
    }
    
    // MARK: - Main Detection Method
    func detectPose(
        from sampleBuffer: CMSampleBuffer,
        timestamp: Double
    ) -> PoseData? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        
        // Get image size
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let imageSize = CGSize(width: width, height: height)
        
        // Get orientation from sample buffer
        let orientation = getImageOrientation(from: sampleBuffer)
        
        // Create request handler with correct orientation
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        
        do {
            try handler.perform([poseRequest])
            
            guard let observation = poseRequest.results?.first else {
                return nil
            }
            
            // Extract joints with coordinate transformation
            let joints = extractJoints(from: observation, imageSize: imageSize)
            let confidences = extractConfidences(from: observation)
            
            return PoseData(
                timestamp: timestamp,
                joints: joints,
                confidences: confidences,
                imageSize: imageSize
            )
            
        } catch {
            print("âŒ Pose detection failed: \(error)")
            return nil
        }
    }
    
    // MARK: - Joint Extraction
    private func extractJoints(
        from observation: VNHumanBodyPoseObservation,
        imageSize: CGSize
    ) -> [BodyJoint: CGPoint] {
        var joints: [BodyJoint: CGPoint] = [:]
        
        // Map Vision joint names to our enum
        let jointMapping: [VNHumanBodyPoseObservation.JointName: BodyJoint] = [
            .neck: .neck,
            .nose: .nose,
            .rightShoulder: .rightShoulder,
            .rightElbow: .rightElbow,
            .rightWrist: .rightWrist,
            .rightHip: .rightHip,
            .rightKnee: .rightKnee,
            .rightAnkle: .rightAnkle,
            .leftShoulder: .leftShoulder,
            .leftElbow: .leftElbow,
            .leftWrist: .leftWrist,
            .leftHip: .leftHip,
            .leftKnee: .leftKnee,
            .leftAnkle: .leftAnkle,
            .root: .root
        ]
        
        for (visionJoint, ourJoint) in jointMapping {
            if let point = try? observation.recognizedPoint(visionJoint),
               point.confidence > minimumConfidence {
                
                // Transform from Vision normalized coordinates to screen coordinates
                // Vision: origin at bottom-left, normalized [0,1]
                // Screen: origin at top-left, pixels
                let screenPoint = transformCoordinate(
                    visionPoint: point.location,
                    imageSize: imageSize
                )
                
                joints[ourJoint] = screenPoint
            }
        }
        
        return joints
    }
    
    private func extractConfidences(
        from observation: VNHumanBodyPoseObservation
    ) -> [BodyJoint: Float] {
        var confidences: [BodyJoint: Float] = [:]
        
        let jointMapping: [VNHumanBodyPoseObservation.JointName: BodyJoint] = [
            .neck: .neck,
            .nose: .nose,
            .rightShoulder: .rightShoulder,
            .rightElbow: .rightElbow,
            .rightWrist: .rightWrist,
            .rightHip: .rightHip,
            .rightKnee: .rightKnee,
            .rightAnkle: .rightAnkle,
            .leftShoulder: .leftShoulder,
            .leftElbow: .leftElbow,
            .leftWrist: .leftWrist,
            .leftHip: .leftHip,
            .leftKnee: .leftKnee,
            .leftAnkle: .leftAnkle,
            .root: .root
        ]
        
        for (visionJoint, ourJoint) in jointMapping {
            if let point = try? observation.recognizedPoint(visionJoint) {
                confidences[ourJoint] = point.confidence
            }
        }
        
        return confidences
    }
    
    // MARK: - Coordinate Transformation
    private func transformCoordinate(
        visionPoint: CGPoint,
        imageSize: CGSize
    ) -> CGPoint {
        // Vision coordinates: (0,0) = bottom-left, (1,1) = top-right
        // Screen coordinates: (0,0) = top-left, (width, height) = bottom-right
        
        let x = visionPoint.x * imageSize.width
        let y = (1.0 - visionPoint.y) * imageSize.height  // Y-flip
        
        return CGPoint(x: x, y: y)
    }
    
    // MARK: - Orientation Handling
    private func getImageOrientation(from sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        // Get orientation from metadata or default to portrait
        guard let attachments = CMCopyDictionaryOfAttachments(
            allocator: kCFAllocatorDefault,
            target: sampleBuffer,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        ) as? [String: Any] else {
            return .up  // Portrait
        }
        
        if let exifOrientation = attachments[kCGImagePropertyOrientation as String] as? UInt32 {
            return CGImagePropertyOrientation(rawValue: exifOrientation) ?? .up
        }
        
        return .up  // Default portrait
    }
}

// MARK: - Angle Calculations
extension PoseDetector {
    /// Calculate angle between three joints (in degrees)
    /// - Parameters:
    ///   - point1: First point (e.g., shoulder)
    ///   - point2: Middle point (e.g., elbow) - vertex of angle
    ///   - point3: Third point (e.g., wrist)
    /// - Returns: Angle in degrees (0-180)
    static func calculateAngle(
        point1: CGPoint,
        point2: CGPoint,
        point3: CGPoint
    ) -> Double {
        // Vectors from point2 to point1 and point3
        let vector1 = CGPoint(x: point1.x - point2.x, y: point1.y - point2.y)
        let vector2 = CGPoint(x: point3.x - point2.x, y: point3.y - point2.y)
        
        // Dot product and magnitudes
        let dotProduct = vector1.x * vector2.x + vector1.y * vector2.y
        let magnitude1 = sqrt(vector1.x * vector1.x + vector1.y * vector1.y)
        let magnitude2 = sqrt(vector2.x * vector2.x + vector2.y * vector2.y)
        
        // Avoid division by zero
        guard magnitude1 > 0 && magnitude2 > 0 else { return 0.0 }
        
        // Calculate angle
        let cosAngle = dotProduct / (magnitude1 * magnitude2)
        let clampedCosAngle = max(-1.0, min(1.0, cosAngle))  // Clamp to [-1, 1]
        let angleRadians = acos(clampedCosAngle)
        
        return angleRadians * 180.0 / .pi
    }
    
    /// Calculate elbow angle (right or left)
    static func calculateElbowAngle(from pose: PoseData, isRight: Bool) -> Double? {
        let shoulder: BodyJoint = isRight ? .rightShoulder : .leftShoulder
        let elbow: BodyJoint = isRight ? .rightElbow : .leftElbow
        let wrist: BodyJoint = isRight ? .rightWrist : .leftWrist
        
        guard let p1 = pose.joints[shoulder],
              let p2 = pose.joints[elbow],
              let p3 = pose.joints[wrist] else {
            return nil
        }
        
        return calculateAngle(point1: p1, point2: p2, point3: p3)
    }
    
    /// Calculate knee angle (right or left)
    static func calculateKneeAngle(from pose: PoseData, isRight: Bool) -> Double? {
        let hip: BodyJoint = isRight ? .rightHip : .leftHip
        let knee: BodyJoint = isRight ? .rightKnee : .leftKnee
        let ankle: BodyJoint = isRight ? .rightAnkle : .leftAnkle
        
        guard let p1 = pose.joints[hip],
              let p2 = pose.joints[knee],
              let p3 = pose.joints[ankle] else {
            return nil
        }
        
        return calculateAngle(point1: p1, point2: p2, point3: p3)
    }
    
    /// Calculate shoulder-pelvis tilt angle (side bend)
    static func calculateShoulderPelvisTilt(from pose: PoseData) -> Double? {
        guard let leftShoulder = pose.joints[.leftShoulder],
              let rightShoulder = pose.joints[.rightShoulder],
              let leftHip = pose.joints[.leftHip],
              let rightHip = pose.joints[.rightHip] else {
            return nil
        }
        
        // Calculate midpoints
        let shoulderMid = CGPoint(
            x: (leftShoulder.x + rightShoulder.x) / 2,
            y: (leftShoulder.y + rightShoulder.y) / 2
        )
        let hipMid = CGPoint(
            x: (leftHip.x + rightHip.x) / 2,
            y: (leftHip.y + rightHip.y) / 2
        )
        
        // Vector from hip to shoulder
        let dx = shoulderMid.x - hipMid.x
        let dy = shoulderMid.y - hipMid.y
        
        // Angle from vertical (0 = perfectly upright)
        let angleRadians = atan2(dx, -dy)  // Negative dy because screen Y is flipped
        let angleDegrees = angleRadians * 180.0 / .pi
        
        return abs(angleDegrees)
    }
}

// MARK: - Debug Helpers
extension PoseData {
    func debugDescription() -> String {
        var desc = "PoseData (timestamp: \(String(format: "%.3f", timestamp))s)\n"
        desc += "Valid: \(isValid), Confidence: \(String(format: "%.2f", averageConfidence))\n"
        desc += "Joints detected: \(joints.count)/\(BodyJoint.allCases.count)\n"
        
        for joint in BodyJoint.allCases {
            if let point = joints[joint],
               let confidence = confidences[joint] {
                desc += "  \(joint.rawValue): (\(Int(point.x)), \(Int(point.y))) conf=\(String(format: "%.2f", confidence))\n"
            }
        }
        
        return desc
    }
}

// =======================
// v0.2 metrics helpers
// =======================

enum Side { case left, right }

extension PoseDetector {

    /// 脇角（上腕-体幹）: neck–shoulder–elbow の外角
    static func armpitAngle(_ pose: PoseData, side: Side) -> Double? {
        let shoulder: BodyJoint = (side == .right) ? .rightShoulder : .leftShoulder
        let elbow: BodyJoint    = (side == .right) ? .rightElbow    : .leftElbow

        guard let neck = pose.joints[ .neck ],
              let sh   = pose.joints[ shoulder ],
              let el   = pose.joints[ elbow ] else { return nil }

        return calculateAngle(point1: neck, point2: sh, point3: el)
    }

    /// 左手位置（2 角度）: torsoAngle = neck–LShoulder–LElbow, extensionAngle = LShoulder–LElbow–LWrist
    static func leftHandAngles(_ pose: PoseData) -> (torso: Double, extension: Double)? {
        guard let neck = pose.joints[ .neck ],
              let ls   = pose.joints[ .leftShoulder ],
              let le   = pose.joints[ .leftElbow ],
              let lw   = pose.joints[ .leftWrist ] else { return nil }

        let torso = calculateAngle(point1: neck, point2: ls, point3: le)
        let ext   = calculateAngle(point1: ls,   point2: le, point3: lw)
        return (torso, ext)
    }

    /// 体軸傾き Δ（腰角/膝角の |θ-180| の平均）
    static func bodyAxisDelta(_ pose: PoseData) -> Double? {
        guard let rs = pose.joints[ .rightShoulder ],
              let rh = pose.joints[ .rightHip ],
              let rk = pose.joints[ .rightKnee ],
              let ra = pose.joints[ .rightAnkle ] else { return nil }

        // 腰角: shoulder–hip–knee / 膝角: hip–knee–ankle
        let waist = calculateAngle(point1: rs, point2: rh, point3: rk)
        let knee  = calculateAngle(point1: rh, point2: rk, point3: ra)
        let d1 = abs(waist - 180.0)
        let d2 = abs(knee  - 180.0)
        return (d1 + d2) / 2.0
    }
}
