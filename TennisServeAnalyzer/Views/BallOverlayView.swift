//
//  BallOverlayView.swift
//  TennisServeAnalyzer
//
//  Created by 島本健生 on 2025/11/06.
//


//
//  BallOverlayView.swift
//  TennisServeAnalyzer
//
//  Real-time ball detection visualization overlay
//

import SwiftUI

// MARK: - Ball Overlay View
struct BallOverlayView: View {
    let ball: BallDetection?
    let viewSize: CGSize
    
    // Configuration
    private let lineWidth: CGFloat = 3
    private let ballColor = Color.yellow
    private let shadowRadius: CGFloat = 3
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let ball = ball, ball.isValid {
                    // Draw ball circle
                    ballCircle(ball: ball, in: geometry.size)
                    
                    // Draw confidence indicator
                    confidenceIndicator(ball: ball, in: geometry.size)
                }
            }
        }
    }
    
    // MARK: - Ball Circle
    private func ballCircle(ball: BallDetection, in size: CGSize) -> some View {
        let scaledPosition = scalePoint(ball.position, from: CGSize(width: 1080, height: 1920), to: size)
        let scaledRadius = ball.radius * (size.width / 1080)
        
        return ZStack {
            // Outer glow
            Circle()
                .stroke(ballColor.opacity(0.3), lineWidth: lineWidth * 2)
                .frame(width: scaledRadius * 2.5, height: scaledRadius * 2.5)
                .position(scaledPosition)
                .blur(radius: 4)
            
            // Main circle
            Circle()
                .stroke(ballColor, lineWidth: lineWidth)
                .frame(width: scaledRadius * 2, height: scaledRadius * 2)
                .position(scaledPosition)
                .shadow(color: .black.opacity(0.5), radius: shadowRadius)
            
            // Center dot
            Circle()
                .fill(ballColor)
                .frame(width: 8, height: 8)
                .position(scaledPosition)
                .shadow(color: ballColor, radius: 4)
        }
    }
    
    // MARK: - Confidence Indicator
    private func confidenceIndicator(ball: BallDetection, in size: CGSize) -> some View {
        let scaledPosition = scalePoint(ball.position, from: CGSize(width: 1080, height: 1920), to: size)
        let scaledRadius = ball.radius * (size.width / 1080)
        
        return VStack(spacing: 2) {
            Text("🎾")
                .font(.caption2)
            
            Text("\(Int(ball.confidence * 100))%")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(confidenceColor(ball.confidence).opacity(0.8))
                )
        }
        .position(
            x: scaledPosition.x,
            y: scaledPosition.y - scaledRadius - 20
        )
        .shadow(color: .black.opacity(0.5), radius: 2)
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
        let scaleX = targetSize.width / sourceSize.width
        let scaleY = targetSize.height / sourceSize.height
        
        return CGPoint(
            x: point.x * scaleX,
            y: point.y * scaleY
        )
    }
}

// MARK: - Preview
#Preview {
    BallOverlayView(
        ball: BallDetection(
            position: CGPoint(x: 540, y: 400),
            radius: 25,
            confidence: 0.85,
            timestamp: 0
        ),
        viewSize: CGSize(width: 375, height: 812)
    )
    .background(Color.black)
}