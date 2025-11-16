//
//  PoseOverlayView.swift
//  TennisServeAnalyzer
//
//  Real-time skeleton visualization overlay with trophy pose angles
//  🔧 修正: TrophyPoseAngles の重複定義を削除
//

import SwiftUI

// MARK: - Pose Overlay View
struct PoseOverlayView: View {
    let pose: PoseData?
    let viewSize: CGSize
    let trophyPoseDetected: Bool
    let trophyAngles: TrophyPoseAngles?  // トロフィーポーズ時の角度
    let pelvisPosition: CGPoint?  // 🔧 追加: 骨盤座標
    
    // Configuration
    private let jointRadius: CGFloat = 8
    private let lineWidth: CGFloat = 3
    private let jointColor = Color.green
    private let lineColor = Color.cyan
    private let trophyHighlightColor = Color.yellow
    private let shadowRadius: CGFloat = 2
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let pose = pose, pose.isValid {
                    // Draw skeleton lines
                    skeletonLines(pose: pose, in: geometry.size)
                    
                    // Draw joints
                    joints(pose: pose, in: geometry.size)
                    
                    // Confidence indicator
                    confidenceIndicator(pose: pose)
                    
                    // 🔧 修正: 角度は常に表示（トロフィーポーズ時は強調）
                    if let angles = trophyAngles {
                        anglesOverlay(angles: angles, isTrophyPose: trophyPoseDetected)
                    }
                }
            }
        }
    }
    
    // MARK: - Angles Overlay (🔧 修正: 常に表示)
    private func anglesOverlay(angles: TrophyPoseAngles, isTrophyPose: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // ヘッダー（トロフィーポーズ時のみ強調表示）
            if isTrophyPose {
                HStack(spacing: 8) {
                    Image(systemName: "trophy.fill")
                        .foregroundColor(.yellow)
                        .font(.title3)
                    
                    Text("トロフィーポーズ検出")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.yellow.opacity(0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.yellow, lineWidth: 2)
                        )
                )
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "figure.stand")
                        .foregroundColor(.white)
                        .font(.title3)
                    
                    Text("リアルタイム角度")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                        )
                )
            }
            
            // 角度データ表示
            VStack(spacing: 4) {
                if let rightElbow = angles.rightElbowAngle {
                    angleRow(
                        label: "右肘",
                        angle: rightElbow,
                        color: .green,
                        isHighlighted: isTrophyPose
                    )
                }
                
                if let rightArmpit = angles.rightArmpitAngle {
                    angleRow(
                        label: "右脇",
                        angle: rightArmpit,
                        color: .green,
                        isHighlighted: isTrophyPose
                    )
                }
                
                if let leftElbow = angles.leftElbowAngle {
                    angleRow(
                        label: "左肘",
                        angle: leftElbow,
                        color: .orange,
                        isHighlighted: isTrophyPose
                    )
                }
                
                if let leftShoulder = angles.leftShoulderAngle {
                    angleRow(
                        label: "左肩",
                        angle: leftShoulder,
                        color: .orange,
                        isHighlighted: isTrophyPose
                    )
                }
                
                // 🔧 追加: 骨盤座標の表示
                if let pelvis = pelvisPosition {
                    pelvisRow(
                        position: pelvis,
                        isHighlighted: isTrophyPose
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(isTrophyPose ? 0.8 : 0.6))
            )
        }
        .padding(.leading, 16)
        .padding(.top, 120)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    // 🔧 追加: 骨盤座標の表示行
    private func pelvisRow(position: CGPoint, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            // ラベル
            Text("骨盤")
                .font(.caption)
                .fontWeight(isHighlighted ? .semibold : .regular)
                .foregroundColor(.white)
                .frame(width: 40, alignment: .leading)
            
            // 座標値
            Text("(\(Int(position.x)), \(Int(position.y)))")
                .font(.caption)
                .fontWeight(isHighlighted ? .bold : .semibold)
                .foregroundColor(.purple)
                .frame(minWidth: 50, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(isHighlighted ? 0.15 : 0.08))
        )
    }
    
    // 角度表示の行コンポーネント（🔧 修正: シンプル版）
    private func angleRow(label: String, angle: Double, color: Color, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            // ラベル
            Text(label)
                .font(.caption)
                .fontWeight(isHighlighted ? .semibold : .regular)
                .foregroundColor(.white)
                .frame(width: 40, alignment: .leading)
            
            // 角度値
            Text("\(String(format: "%.1f", angle))°")
                .font(.caption)
                .fontWeight(isHighlighted ? .semibold : .regular)
                .monospacedDigit()
                .foregroundColor(color)
                .frame(minWidth: 50, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(isHighlighted ? 0.15 : 0.08))
        )
    }
    
    // MARK: - Skeleton Lines
    private func skeletonLines(pose: PoseData, in size: CGSize) -> some View {
        ZStack {
            // Torso
            drawLine(from: .neck, to: .root, in: pose, size: size)
            
            // Right arm
            drawLine(from: .rightShoulder, to: .rightElbow, in: pose, size: size)
            drawLine(from: .rightElbow, to: .rightWrist, in: pose, size: size)
            drawLine(from: .neck, to: .rightShoulder, in: pose, size: size)
            
            // Left arm
            drawLine(from: .leftShoulder, to: .leftElbow, in: pose, size: size)
            drawLine(from: .leftElbow, to: .leftWrist, in: pose, size: size)
            drawLine(from: .neck, to: .leftShoulder, in: pose, size: size)
            
            // Right leg
            drawLine(from: .root, to: .rightHip, in: pose, size: size)
            drawLine(from: .rightHip, to: .rightKnee, in: pose, size: size)
            drawLine(from: .rightKnee, to: .rightAnkle, in: pose, size: size)
            
            // Left leg
            drawLine(from: .root, to: .leftHip, in: pose, size: size)
            drawLine(from: .leftHip, to: .leftKnee, in: pose, size: size)
            drawLine(from: .leftKnee, to: .leftAnkle, in: pose, size: size)
        }
    }
    
    private func drawLine(from joint1: BodyJoint, to joint2: BodyJoint, in pose: PoseData, size: CGSize) -> some View {
        Group {
            if let point1 = pose.joints[joint1],
               let point2 = pose.joints[joint2],
               let conf1 = pose.confidences[joint1],
               let conf2 = pose.confidences[joint2],
               conf1 > 0.3 && conf2 > 0.3 {
                
                let scaled1 = scalePoint(point1, from: pose.imageSize, to: size)
                let scaled2 = scalePoint(point2, from: pose.imageSize, to: size)
                
                Path { path in
                    path.move(to: scaled1)
                    path.addLine(to: scaled2)
                }
                .stroke(lineColor, lineWidth: lineWidth)
                .shadow(color: .black.opacity(0.5), radius: shadowRadius)
            }
        }
    }
    
    // MARK: - Joints
    private func joints(pose: PoseData, in size: CGSize) -> some View {
        ForEach(Array(pose.joints.keys), id: \.rawValue) { joint in
            if let point = pose.joints[joint],
               let confidence = pose.confidences[joint],
               confidence > 0.3 {
                
                let scaledPoint = scalePoint(point, from: pose.imageSize, to: size)
                
                // Highlight trophy pose key joints (elbows and wrists)
                let isTrophyJoint = trophyPoseDetected && (
                    joint == .rightElbow || joint == .rightWrist ||
                    joint == .leftElbow || joint == .leftWrist ||
                    joint == .rightShoulder || joint == .leftShoulder
                )
                
                let color = isTrophyJoint ? trophyHighlightColor : jointColor
                let radius = isTrophyJoint ? jointRadius * 1.5 : jointRadius
                
                Circle()
                    .fill(color)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(scaledPoint)
                    .shadow(color: .black.opacity(0.5), radius: shadowRadius)
                    .opacity(Double(confidence))
                
                // Add pulsing ring for trophy joints
                if isTrophyJoint {
                    Circle()
                        .stroke(trophyHighlightColor, lineWidth: 2)
                        .frame(width: radius * 3, height: radius * 3)
                        .position(scaledPoint)
                        .opacity(0.6)
                }
            }
        }
    }
    
    // MARK: - Confidence Indicator
    private func confidenceIndicator(pose: PoseData) -> some View {
        VStack {
            Spacer()
            
            HStack(spacing: 8) {
                Circle()
                    .fill(confidenceColor(pose.averageConfidence))
                    .frame(width: 12, height: 12)
                
                Text("Confidence: \(Int(pose.averageConfidence * 100))%")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
            }
            .padding(.bottom, 100)
        }
    }
    
    private func confidenceColor(_ confidence: Float) -> Color {
        if confidence > 0.7 {
            return .green
        } else if confidence > 0.5 {
            return .yellow
        } else {
            return .orange
        }
    }
    
    // MARK: - Coordinate Transformation
    private func scalePoint(_ point: CGPoint, from sourceSize: CGSize, to targetSize: CGSize) -> CGPoint {
        // Calculate scale factors
        let scaleX = targetSize.width / sourceSize.width
        let scaleY = targetSize.height / sourceSize.height
        
        return CGPoint(
            x: point.x * scaleX,
            y: point.y * scaleY
        )
    }
}

// 🔧 削除: TrophyPoseAngles の重複定義を削除（TrophyPoseAngles.swift で定義）

// MARK: - Preview
#Preview {
    PoseOverlayView(
        pose: nil,
        viewSize: CGSize(width: 375, height: 812),
        trophyPoseDetected: false,  // リアルタイム表示のプレビュー
        trophyAngles: TrophyPoseAngles(
            rightElbow: 165.0,
            rightArmpit: 95.0,
            leftElbow: 170.0,
            leftShoulder: 65.0
        ),
        pelvisPosition: CGPoint(x: 187, y: 400)  // 🔧 追加: プレビュー用の骨盤座標
    )
    .background(Color.black)
}
