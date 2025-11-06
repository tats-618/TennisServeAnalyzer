//
//  CourtCalibrationView.swift
//  TennisServeAnalyzer
//
//  Created by 島本健生 on 2025/11/06.
//


import SwiftUI

struct CourtCalibrationView: View {
    @StateObject private var calibration = CourtCalibration()
    @State private var showingCamera = true
    
    var body: some View {
        ZStack {
            // カメラプレビュー
            if showingCamera {
                CameraPreviewForCalibration(calibration: calibration)
                    .edgesIgnoringSafeArea(.all)
            }
            
            // オーバーレイUI
            VStack {
                // インストラクション
                InstructionBanner(
                    pointsCollected: calibration.calibrationPoints.count,
                    isCalibrated: calibration.isCalibrated
                )
                .padding()
                
                Spacer()
                
                // 点の表示
                GeometryReader { geometry in
                    ForEach(Array(calibration.calibrationPoints.enumerated()), id: \.offset) { index, point in
                        CalibrationPointMarker(
                            number: index + 1,
                            position: point
                        )
                    }
                }
                
                Spacer()
                
                // コントロール
                CalibrationControls(calibration: calibration)
                    .padding()
            }
        }
        .navigationTitle("コートキャリブレーション")
    }
}

struct InstructionBanner: View {
    let pointsCollected: Int
    let isCalibrated: Bool
    
    var body: some View {
        VStack(spacing: 8) {
            if isCalibrated {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("キャリブレーション完了")
                        .fontWeight(.semibold)
                }
            } else {
                Text(instructionText)
                    .font(.body)
                    .multilineTextAlignment(.center)
                
                ProgressView(value: Double(pointsCollected), total: 4.0)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                
                Text("\(pointsCollected)/4 点")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.black.opacity(0.7))
        .cornerRadius(12)
    }
    
    private var instructionText: String {
        switch pointsCollected {
        case 0:
            return "1. ベースライン左端をタップ"
        case 1:
            return "2. ベースライン右端をタップ"
        case 2:
            return "3. 1m前方の左端をタップ"
        case 3:
            return "4. 1m前方の右端をタップ"
        default:
            return ""
        }
    }
}

struct CalibrationPointMarker: View {
    let number: Int
    let position: CGPoint
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green)
                .frame(width: 40, height: 40)
                .position(position)
            
            Circle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: 40, height: 40)
                .position(position)
            
            Text("\(number)")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .position(position)
        }
    }
}

struct CalibrationControls: View {
    @ObservedObject var calibration: CourtCalibration
    
    var body: some View {
        HStack(spacing: 16) {
            Button(action: { calibration.reset() }) {
                Label("リセット", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            
            if calibration.isCalibrated {
                Button(action: { /* 次へ */ }) {
                    Label("完了", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }
        }
    }
}

struct CameraPreviewForCalibration: UIViewRepresentable {
    @ObservedObject var calibration: CourtCalibration
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        
        // タップジェスチャー
        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tapGesture)
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(calibration: calibration)
    }
    
    class Coordinator {
        let calibration: CourtCalibration
        
        init(calibration: CourtCalibration) {
            self.calibration = calibration
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            let location = gesture.location(in: gesture.view)
            calibration.addPoint(location)
        }
    }
}