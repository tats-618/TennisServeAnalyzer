//
//  TrophyPoseAngles.swift
//  TennisServeAnalyzer
//
//  Trophy pose angle data for UI overlay
//

import Foundation

/// トロフィーポーズの角度データ（UI表示用）
struct TrophyPoseAngles {
    let rightElbowAngle: Double?    // 右肘角度
    let rightArmpitAngle: Double?   // 右脇角度
    let leftElbowAngle: Double?     // 左肘角度
    let leftShoulderAngle: Double?  // 左肩角度
    
    // 🔧 追加: 簡易イニシャライザ（右側のみ）
    init(rightElbow: Double, rightArmpit: Double) {
        self.rightElbowAngle = rightElbow
        self.rightArmpitAngle = rightArmpit
        self.leftElbowAngle = nil
        self.leftShoulderAngle = nil
    }
    
    // 🔧 追加: 完全イニシャライザ（全角度）
    init(rightElbow: Double?, rightArmpit: Double?, leftElbow: Double?, leftShoulder: Double?) {
        self.rightElbowAngle = rightElbow
        self.rightArmpitAngle = rightArmpit
        self.leftElbowAngle = leftElbow
        self.leftShoulderAngle = leftShoulder
    }
}
