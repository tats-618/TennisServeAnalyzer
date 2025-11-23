//
//  BaselineOverlayView.swift
//  TennisServeAnalyzer
//
//  🎯 ベースラインキャリブレーション用オーバーレイ
//  カメラをコートのベースラインに合わせるための参照線
//

import SwiftUI

struct BaselineOverlayView: View {
    let viewSize: CGSize
    
    // Configuration
    private let lineColor = Color.red
    private let lineWidth: CGFloat = 3
    private let shadowRadius: CGFloat = 4
    private let brandAccent = Color(red: 0.8, green: 1.0, blue: 0.0) // Tennis Ball Green
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // メイン基準線（画面中央）
                baselineIndicator(in: geometry.size)
                
                // 補助グリッド線（オプション）
                gridLines(in: geometry.size)
                
                // 説明テキスト
                instructionLayer
            }
        }
    }
    
    // MARK: - メイン基準線
    private func baselineIndicator(in size: CGSize) -> some View {
        let centerX = size.width / 2
        
        return ZStack {
            // 影付き外側線
            Rectangle()
                .fill(lineColor.opacity(0.3))
                .frame(width: lineWidth * 2, height: size.height)
                .position(x: centerX, y: size.height / 2)
                .blur(radius: shadowRadius)
            
            // メイン線
            Rectangle()
                .fill(lineColor)
                .frame(width: lineWidth, height: size.height)
                .position(x: centerX, y: size.height / 2)
                .shadow(color: .black.opacity(0.5), radius: shadowRadius)
            
            // 中央マーカー（強調）
            Circle()
                .fill(lineColor)
                .frame(width: 20, height: 20)
                .position(x: centerX, y: size.height / 2)
                .shadow(color: lineColor, radius: 8)
            
            // 上部マーカー
            Circle()
                .stroke(lineColor, lineWidth: 2)
                .frame(width: 16, height: 16)
                .position(x: centerX, y: size.height * 0.2)
            
            // 下部マーカー
            Circle()
                .stroke(lineColor, lineWidth: 2)
                .frame(width: 16, height: 16)
                .position(x: centerX, y: size.height * 0.8)
        }
    }
    
    // MARK: - 補助グリッド線
    private func gridLines(in size: CGSize) -> some View {
        let centerX = size.width / 2
        let spacing: CGFloat = size.width / 6  // 画面を6分割
        
        return ZStack {
            // 左側の補助線
            ForEach(-2...(-1), id: \.self) { i in
                let x = centerX + CGFloat(i) * spacing
                
                Rectangle()
                    .fill(lineColor.opacity(0.2))
                    .frame(width: 1, height: size.height)
                    .position(x: x, y: size.height / 2)
            }
            
            // 右側の補助線
            ForEach(1...2, id: \.self) { i in
                let x = centerX + CGFloat(i) * spacing
                
                Rectangle()
                    .fill(lineColor.opacity(0.2))
                    .frame(width: 1, height: size.height)
                    .position(x: x, y: size.height / 2)
            }
            
            // 水平補助線（上下1/3の位置）
            Rectangle()
                .fill(lineColor.opacity(0.15))
                .frame(width: size.width, height: 1)
                .position(x: size.width / 2, y: size.height / 3)
            
            Rectangle()
                .fill(lineColor.opacity(0.15))
                .frame(width: size.width, height: 1)
                .position(x: size.width / 2, y: size.height * 2 / 3)
        }
    }
    
    // MARK: - 3. Instruction Layer
        private var instructionLayer: some View {
            VStack {
                Spacer()
                
                // ガイドテキスト
                HStack(spacing: 16) {
                    // アイコンエリア
                    ZStack {
                        Circle()
                            .fill(brandAccent.opacity(0.2))
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: "lines.measurement.horizontal")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(brandAccent)
                    }
                    
                    // テキストエリア
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ベースラインに合わせてください")
                            .font(.system(.subheadline, design: .rounded))
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                        
                        Text("赤の線が基準になります")
                            .font(.system(.caption, design: .rounded))
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    
                    Spacer()
                }
                .padding(16)
                .background(.ultraThinMaterial) // すりガラス効果
                .cornerRadius(24)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                .padding(.horizontal, 24)
                // ContentViewのボタン類と重ならないように底上げ
                .padding(.bottom, 130)
            }
        }
    }

// MARK: - Preview
#Preview {
    ZStack {
        // 背景（カメラプレビューの代わり）
        Color.gray.edgesIgnoringSafeArea(.all)
        
        BaselineOverlayView(
            viewSize: CGSize(width: 375, height: 812)
        )
    }
}
