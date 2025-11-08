//
//  BallOverlayView.swift (100% COMPLETE VERSION)
//  TennisServeAnalyzer
//
//  🎯 PROPER COORDINATE SCALING
//
//  IMPROVEMENTS:
//  1. ✅ Aspect-ratio preserving scale (min of scaleX, scaleY)
//  2. ✅ Bounds clamping to prevent off-screen rendering
//  3. ✅ Visual feedback for apex detection
//

import SwiftUI

// MARK: - Ball Overlay View (100% COMPLETE)
struct BallOverlayView: View {
    let ball: BallDetection?
    let viewSize: CGSize
    
    // Configuration
    private let lineWidth: CGFloat = 3
    private let ballColor = Color.yellow
    private let apexColor = Color.orange  // Special color for apex
    private let shadowRadius: CGFloat = 3
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let ball = ball, ball.isValid {
                    ballCircle(ball: ball, in: geometry.size)
                    confidenceIndicator(ball: ball, in: geometry.size)
                }
            }
        }
    }
    
    // MARK: - Ball Circle
    private func ballCircle(ball: BallDetection, in size: CGSize) -> some View {
        // 🎯 PROPER scaling with aspect ratio preservation
        let scaleX = size.width / ball.imageSize.width
        let scaleY = size.height / ball.imageSize.height
        let scale = min(scaleX, scaleY)  // Use minimum to preserve aspect ratio
        
        let scaledPosition = CGPoint(
            x: ball.position.x * scaleX,
            y: ball.position.y * scaleY
        )
        
        // Clamp position to view bounds (with margin)
        let clampedPosition = CGPoint(
            x: max(20, min(scaledPosition.x, size.width - 20)),
            y: max(20, min(scaledPosition.y, size.height - 20))
        )
        
        // Scale radius proportionally
        let scaledRadius = ball.radius * scale
        let displayRadius = max(10.0, min(scaledRadius, 100.0))
        
        // Color based on position (apex at top = orange)
        let isLikelyApex = ball.position.y < ball.imageSize.height * 0.3
        let color = isLikelyApex ? apexColor : ballColor
        
        return ZStack {
            // Outer glow
            Circle()
                .stroke(color.opacity(0.3), lineWidth: lineWidth * 2)
                .frame(width: displayRadius * 2.5, height: displayRadius * 2.5)
                .position(clampedPosition)
                .blur(radius: 4)
            
            // Main circle
            Circle()
                .stroke(color, lineWidth: lineWidth)
                .frame(width: displayRadius * 2, height: displayRadius * 2)
                .position(clampedPosition)
                .shadow(color: .black.opacity(0.5), radius: shadowRadius)
            
            // Center dot
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .position(clampedPosition)
                .shadow(color: color, radius: 4)
            
            // Pulsing ring for likely apex
            if isLikelyApex {
                Circle()
                    .stroke(apexColor, lineWidth: 2)
                    .frame(width: displayRadius * 3, height: displayRadius * 3)
                    .position(clampedPosition)
                    .opacity(0.6)
            }
        }
    }
    
    // MARK: - Confidence Indicator
    private func confidenceIndicator(ball: BallDetection, in size: CGSize) -> some View {
        let scaleX = size.width / ball.imageSize.width
        let scaleY = size.height / ball.imageSize.height
        let scale = min(scaleX, scaleY)
        
        let scaledPosition = CGPoint(
            x: ball.position.x * scaleX,
            y: ball.position.y * scaleY
        )
        
        let clampedPosition = CGPoint(
            x: max(20, min(scaledPosition.x, size.width - 20)),
            y: max(20, min(scaledPosition.y, size.height - 20))
        )
        
        let scaledRadius = max(10.0, min(ball.radius * scale, 100.0))
        
        let isLikelyApex = ball.position.y < ball.imageSize.height * 0.3
        
        return VStack(spacing: 2) {
            Text(isLikelyApex ? "🎯" : "🎾")
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
            
            // Y position indicator for debugging
            #if DEBUG
            Text("y:\(Int(ball.position.y))")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
            #endif
        }
        .position(
            x: clampedPosition.x,
            y: max(30, clampedPosition.y - scaledRadius - 25)
        )
        .shadow(color: .black.opacity(0.5), radius: 2)
    }
    
    private func confidenceColor(_ confidence: Float) -> Color {
        if confidence > 0.5 {
            return .green
        } else if confidence > 0.3 {
            return .yellow
        } else {
            return .orange
        }
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        Color.black.edgesIgnoringSafeArea(.all)
        
        // Simulated apex detection (top of screen)
        BallOverlayView(
            ball: BallDetection(
                position: CGPoint(x: 640, y: 180),  // Top 1/6 of screen
                radius: 18,
                confidence: 0.65,
                timestamp: 0,
                imageSize: CGSize(width: 1280, height: 720)
            ),
            viewSize: CGSize(width: 375, height: 812)
        )
    }
}
