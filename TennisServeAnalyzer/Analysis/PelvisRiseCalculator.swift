//
//  PelvisRiseCalculator.swift
//  TennisServeAnalyzer
//
//  Created by 島本健生 on 2025/11/06.
//


//
//  PelvisRiseCalculator.swift
//  TennisServeAnalyzer
//
//  Calculate pelvis vertical rise from trophy to impact
//

import Foundation
import CoreGraphics

class PelvisRiseCalculator {
    // 身長固定（設計書通り）
    private let playerHeight: Double = 1.70  // m
    
    // 人体比率（股関節→足首 ≈ 0.53H）
    private let hipToAnkleRatio: Double = 0.53
    
    /// 骨盤上昇量を計算
    /// - Parameters:
    ///   - trophyPose: トロフィーポーズ時の姿勢
    ///   - impactPose: インパクト時の姿勢（または直前20-30ms）
    /// - Returns: 上昇量（メートル）
    func calculatePelvisRise(
        trophyPose: PoseData,
        impactPose: PoseData
    ) -> Double? {
        // 骨盤中心を計算（左右ヒップの中点）
        guard let trophyPelvis = calculatePelvisCenter(from: trophyPose),
              let impactPelvis = calculatePelvisCenter(from: impactPose) else {
            return nil
        }
        
        // ピクセル単位の上昇量
        let deltaY_px = trophyPelvis.y - impactPelvis.y  // 画面上部が0なので符号反転
        
        // メートル化スケール係数を計算
        guard let scale = calculatePixelToMeterScale(from: trophyPose) else {
            return nil
        }
        
        // メートル単位の上昇量
        let deltaZ_m = Double(deltaY_px) * scale
        
        print("📏 Pelvis rise: \(String(format: "%.3f", deltaZ_m))m (px: \(deltaY_px))")
        
        return deltaZ_m
    }
    
    /// 骨盤中心を計算
    private func calculatePelvisCenter(from pose: PoseData) -> CGPoint? {
        guard let leftHip = pose.joints[.leftHip],
              let rightHip = pose.joints[.rightHip] else {
            return nil
        }
        
        return CGPoint(
            x: (leftHip.x + rightHip.x) / 2,
            y: (leftHip.y + rightHip.y) / 2
        )
    }
    
    /// ピクセル→メートル変換係数を計算
    /// 正規化基準長：股関節→足首の画素長
    private func calculatePixelToMeterScale(from pose: PoseData) -> Double? {
        // 右脚で計算（左脚でも可）
        guard let hip = pose.joints[.rightHip],
              let ankle = pose.joints[.rightAnkle] else {
            return nil
        }
        
        // ピクセル長
        let dx = hip.x - ankle.x
        let dy = hip.y - ankle.y
        let L_px = sqrt(dx * dx + dy * dy)
        
        // 実世界の長さ（メートル）
        let L_m = playerHeight * hipToAnkleRatio  // 1.70 * 0.53 = 0.901m
        
        // スケール係数（m/px）
        let scale = L_m / Double(L_px)
        
        print("📐 Scale factor: \(String(format: "%.6f", scale)) m/px (hip-ankle: \(L_px)px)")
        
        return scale
    }
}