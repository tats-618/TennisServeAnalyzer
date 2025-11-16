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
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // メイン基準線（画面中央）
                baselineIndicator(in: geometry.size)
                
                // 補助グリッド線（オプション）
                gridLines(in: geometry.size)
                
                // 説明テキスト
                instructionText(in: geometry.size)
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
    
    // MARK: - 説明テキスト
    private func instructionText(in size: CGSize) -> some View {
        VStack {
            // 上部の説明
            VStack(spacing: 8) {
                Text("📍 カメラ設置")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("赤い線をベースラインに合わせてください")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
                
                Text("ベースライン = サーブを打つ位置の基準線")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 30)
            .background(
                RoundedRectangle(cornerRadius: 15)
                    .fill(Color.black.opacity(0.6))
                    .shadow(color: .black.opacity(0.3), radius: 8)
            )
            .padding(.top, 60)
            
            Spacer()
            
            // 下部の詳細ガイド
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "camera.viewfinder")
                        .font(.title2)
                        .foregroundColor(lineColor)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("設置のポイント")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        Text("• 赤い線とベースラインを合わせる")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                        
                        Text("• カメラは真横から水平に")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                        
                        Text("• 全身が映る高さに調整")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 15)
                    .fill(Color.black.opacity(0.6))
                    .shadow(color: .black.opacity(0.3), radius: 8)
            )
            .padding(.bottom, 140)  // ボタンの上に余白
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
