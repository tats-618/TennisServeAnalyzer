//
//  MetricsCalculator.swift
//  TennisServeAnalyzer
//
//  v0.2 — 8-Metric Calculation and Scoring (0–100 normalized)
//  ※ 後方互換のため calculateMetrics に末尾パラメータを追加（デフォルト引数）
//

import Foundation
import CoreGraphics

// MARK: - Serve Metrics (v0.2 定義に同期)
struct ServeMetrics: Codable {
    // Raw values (8 指標)
    public let elbowAngleDeg: Double                 // 1: 肘角（Trophy）
    public let armpitAngleDeg: Double               // 2: 脇角（Trophy）
    public let pelvisRisePx: Double                 // 3: 下半身貢献度（Trophy前後0.5秒の骨盤上昇[px]）
    public let leftArmTorsoAngleDeg: Double         // 4a: 左手位置（体幹-左腕）
    public let leftArmExtensionDeg: Double          // 4b: 左手位置（上腕-前腕）
    public let bodyAxisDeviationDeg: Double         // 5: 体軸傾き（腰角/膝角の偏差平均, Impact）
    public let racketFaceYawDeg: Double             // 6a: ラケット面（Yaw）
    public let racketFacePitchDeg: Double           // 6b: ラケット面（Pitch）
    public let tossForwardDistanceM: Double         // 7: トス前方距離[m]
    public let wristRotationDeg: Double             // 8: リストワーク（Trophy→Impactの回内外合計角度）

    // Scores (0–100)
    public let score1_elbowAngle: Int
    public let score2_armpitAngle: Int
    public let score3_lowerBodyContribution: Int
    public let score4_leftHandPosition: Int
    public let score5_bodyAxisTilt: Int
    public let score6_racketFaceAngle: Int
    public let score7_tossPosition: Int
    public let score8_wristwork: Int

    // Total score (weighted)
    public let totalScore: Int

    // Metadata
    public let timestamp: Date
    public let flags: [String] // 不足データなどの注記
}

// MARK: - Weights (sum = 100) ※現在は使用していません（単純平均に変更）
/*
private let METRIC_WEIGHTS: [Double] = [
    10, // 1 肘
    10, // 2 脇
    20, // 3 下半身貢献
    10, // 4 左手位置
    15, // 5 体軸
    10, // 6 ラケット面
    10, // 7 トス位置
    15  // 8 リストワーク
]
*/

// MARK: - Calculator
enum MetricsCalculator {

    /// v0.2 指標でのメイン計算
    /// - Parameters:
    ///   - trophyPose: トロフィーポーズイベント（pose / timestamp / elbowAngle など）
    ///   - impactEvent: インパクトイベント（monotonicMs / 可能なら pose）
    ///   - tossHistory: ボール頂点検出履歴（トス位置推定に使用）
    ///   - imuHistory: Trophy→Impact 区間のIMUサンプル
    ///   - calibration: ラケット座標系キャリブ結果（任意）
    ///   - courtCalibration: コートホモグラフィ（任意, あれば[m]へ換算）
    ///   - impactPose: 可能ならインパクト時のPose（任意, 未指定ならTrophyで代替）
    ///   - pelvisBasePose: 骨盤測定の基準位置（最も低い位置）、任意
    static func calculateMetrics(
        trophyPose: TrophyPoseEvent,
        impactEvent: ImpactEvent,
        tossHistory: [BallDetection],
        imuHistory: [ServeSample],
        calibration: CalibrationResult? = nil,
        courtCalibration: CourtCalibration? = nil,
        impactPose: PoseData? = nil,
        pelvisBasePose: PoseData? = nil
    ) -> ServeMetrics {

        var flags: [String] = []

        // ========= 1) 肘角（Trophy） =========
        // 🔧 修正: rightElbowAngle（実際の頂点角度）を優先
        let elbowAngle = trophyPose.rightElbowAngle
            ?? trophyPose.elbowAngle
            ?? PoseDetector.calculateElbowAngle(from: trophyPose.pose, isRight: true) ?? 0.0
        let score1 = scoreElbowAngle(elbowAngle)

        // ========= 2) 脇角（Trophy） =========
        // 🔧 修正: rightArmpitAngle（実際の頂点角度）を優先
        let armpit = trophyPose.rightArmpitAngle
            ?? PoseDetector.armpitAngle(trophyPose.pose, side: .right) ?? 0.0
        let score2 = scoreArmpitAngle(armpit)

        // ========= 3) 下半身貢献度（骨盤上昇[px]）=========
        // 最も低い位置（pelvisBasePose）から最も高い位置（impactPose）への上昇量を測定
        let impactPoseResolved = impactPose ?? trophyPose.pose // フォールバック
        let basePoseResolved = pelvisBasePose ?? trophyPose.pose // 基準位置（最も低い位置）
        var pelvisRisePx = pelvisRisePixels(basePoseResolved, impactPoseResolved)
        if impactPose == nil { flags.append("no_impact_pose_for_pelvisRise") }
        if pelvisBasePose == nil { flags.append("no_pelvis_base_pose") }
        let score3 = scorePelvisRise(pelvisRisePx)

        // ========= 4) 左手位置（Trophy）=========
        // 🔧 修正: leftShoulderAngleとleftElbowAngle（実際の頂点角度）を優先
        let leftTorso = trophyPose.leftShoulderAngle
            ?? PoseDetector.leftHandAngles(trophyPose.pose)?.torso ?? Double.nan
        let leftExt = trophyPose.leftElbowAngle
            ?? PoseDetector.calculateElbowAngle(from: trophyPose.pose, isRight: false) ?? Double.nan
        let score4 = scoreLeftHandPosition(torsoAngle: leftTorso, extensionAngle: leftExt)

        // ========= 5) 体軸傾き（Impact 時理想, なければ Trophy）=========
        let bodyAxis = PoseDetector.bodyAxisDelta(impactPoseResolved) ?? 999.0
        if bodyAxis == 999.0 { flags.append("body_axis_calc_failed") }
        let score5 = scoreBodyAxisTilt(bodyAxis)

        // ========= 6) ラケット面角（Pitch / Yaw）=========
        // キャリブレーションが無ければ近傍 IMU から近似（小窓積分の変位角）
        let (rfYaw, rfPitch, rfFlag) = estimateRacketFace(imuHistory: imuHistory,
                                                          impactMs: impactEvent.monotonicMs,
                                                          calibration: calibration)
        if let f = rfFlag { flags.append(f) }
        let score6 = scoreRacketFace(yaw: rfYaw, pitch: rfPitch)

        // ========= 7) トス前進距離[m] =========
        let (tossM, tossFlag) = estimateTossForwardDistance(
            tossHistory: tossHistory,
            poseRef: trophyPose.pose,
            courtCalib: courtCalibration
        )
        if let f = tossFlag { flags.append(f) }
        let score7 = scoreTossForward(tossM)

        // ========= 8) リストワーク（合計回内外角度）=========
        let wristDeg = estimateWristRotationDeg(
            imuHistory: imuHistory,
            startMs: Int64(trophyPose.timestamp * 1000.0),
            endMs: impactEvent.monotonicMs
        )
        let score8 = scoreWristwork(wristDeg)

        // ========= 合計（8項目の単純平均）=========
        let scores = [score1, score2, score3, score4, score5, score6, score7, score8]
        let total = Double(scores.reduce(0, +)) / 8.0  // 単純平均


        return ServeMetrics(
            elbowAngleDeg: elbowAngle,
            armpitAngleDeg: armpit,
            pelvisRisePx: pelvisRisePx,
            leftArmTorsoAngleDeg: leftTorso,
            leftArmExtensionDeg: leftExt,
            bodyAxisDeviationDeg: bodyAxis,
            racketFaceYawDeg: rfYaw,
            racketFacePitchDeg: rfPitch,
            tossForwardDistanceM: tossM,
            wristRotationDeg: wristDeg,
            score1_elbowAngle: score1,
            score2_armpitAngle: score2,
            score3_lowerBodyContribution: score3,
            score4_leftHandPosition: score4,
            score5_bodyAxisTilt: score5,
            score6_racketFaceAngle: score6,
            score7_tossPosition: score7,
            score8_wristwork: score8,
            totalScore: Int(total),
            timestamp: Date(),
            flags: flags
        )
    }

    // MARK: - Angle Normalization (360° support)
    /// 360°範囲の角度を0°～180°に正規化
    /// - 0°～180°: そのまま
    /// - 180°～360°: 360° - angle（反対方向として解釈）
    private static func normalizeAngle(_ angle: Double) -> Double {
        if angle <= 180.0 {
            return angle
        } else {
            return 360.0 - angle
        }
    }

    // MARK: - 1) 肘角
    private static func scoreElbowAngle(_ angle: Double) -> Int {
        // 🔧 設計書準拠: 360°範囲を0°～180°に正規化
        let normalizedAngle = normalizeAngle(angle)
        
        // 設計書基準:
        // - 理想範囲 90°~110° → 100点
        // - 曲がりすぎ 0°~89.9° → 100×(θ/90)
        // - 伸ばしすぎ 110.1°~180° → 100×((180−θ)/70)
        
        if (90...110).contains(normalizedAngle) {
            return 100
        } else if normalizedAngle < 90 {
            // 曲がりすぎ
            return Int(100.0 * normalizedAngle / 90.0)
        } else {
            // 伸ばしすぎ (110.1° ~ 180°)
            return Int(100.0 * (180.0 - normalizedAngle) / 70.0)
        }
    }

    // MARK: - 2) 脇角（上腕-体幹の外角）
    private static func scoreArmpitAngle(_ angle: Double) -> Int {
        // 🔧 設計書準拠: 360°対応 - 基準値 170–190°
        // 設計書基準:
        // - 理想範囲 170°~190° → 100点
        // - 下がりすぎ 90°~169.9° → 100×((θ−90)/80)
        // - 上がりすぎ 190.1°~270° → 100×((270−θ)/80)
        
        if (170...190).contains(angle) {
            return 100
        } else if (90..<170).contains(angle) {
            // 下がりすぎ
            return Int(100.0 * (angle - 90.0) / 80.0)
        } else if (190..<270).contains(angle) {
            // 上がりすぎ
            return Int(100.0 * (270.0 - angle) / 80.0)
        } else {
            // 範囲外 (90°未満または270°以上)
            return 0
        }
    }

    // MARK: - 3) 下半身貢献度（骨盤上昇）
    private static func pelvisRisePixels(_ trophy: PoseData, _ impact: PoseData) -> Double {
        // 右/左 Hip の中点のY差をピクセルで返す
        guard let rH = trophy.joints[.rightHip], let lH = trophy.joints[.leftHip],
              let rH2 = impact.joints[.rightHip], let lH2 = impact.joints[.leftHip] else {
            return 0.0
        }
        let hipMid1 = CGPoint(x: (rH.x + lH.x)/2, y: (rH.y + lH.y)/2)
        let hipMid2 = CGPoint(x: (rH2.x + lH2.x)/2, y: (rH2.y + lH2.y)/2)

        // ピクセル上昇量（画面座標で y 減少 = 上昇）
        let pixRise = max(0.0, hipMid1.y - hipMid2.y)
        return Double(pixRise)
    }
    
    // 🔧 追加: 骨盤座標とピクセル移動量を含む詳細情報を返す関数
    static func pelvisRiseDetails(_ trophy: PoseData, _ impact: PoseData) -> (pixels: Double, hipTrophy: CGPoint?, hipImpact: CGPoint?)? {
        guard let rH = trophy.joints[.rightHip], let lH = trophy.joints[.leftHip],
              let rH2 = impact.joints[.rightHip], let lH2 = impact.joints[.leftHip] else {
            return nil
        }
        
        let hipMid1 = CGPoint(x: (rH.x + lH.x)/2, y: (rH.y + lH.y)/2)
        let hipMid2 = CGPoint(x: (rH2.x + lH2.x)/2, y: (rH2.y + lH2.y)/2)

        let pixRise = max(0.0, hipMid1.y - hipMid2.y)
        
        return (pixels: Double(pixRise), hipTrophy: hipMid1, hipImpact: hipMid2)
    }

    private static func scorePelvisRise(_ pixels: Double) -> Int {
        // 🔧 設計書準拠: ピクセルベースの基準値
        // - 理想範囲 60~70 px → 100点
        // - 不足 0~59.9 px → (100×ΔY)/60
        
        if (60...70).contains(pixels) {
            return 100
        } else if pixels < 60 {
            // 不足（膝が使えていない）
            return Int(100.0 * pixels / 60.0)
        } else {
            // 70pxを超える場合も100点とする
            return 100
        }
    }

    // MARK: - 4) 左手位置（体幹-左腕 & 上腕-前腕の2角度の合成）
    private static func scoreLeftHandPosition(torsoAngle: Double, extensionAngle: Double) -> Int {
        // 🔧 設計書準拠: 左肩（torsoAngle）は360°対応、左肘（extensionAngle）は180°のまま
        let normalizedExtension = normalizeAngle(extensionAngle)
        
        // 設計書基準 - 左肩（torsoAngle）: 90°~120° → 50点
        // - 低すぎ 0°~89.9° → 50×((90-θ)/90)
        // - 後ろに曲げすぎ 120.1°~270° → 50×((270−θ)/150)
        let s1: Int
        if (90...120).contains(torsoAngle) {
            s1 = 50
        } else if torsoAngle < 90 {
            // 低すぎ
            s1 = Int(50.0 * (90.0 - torsoAngle) / 90.0)
        } else if torsoAngle <= 270 {
            // 後ろに曲げすぎ
            s1 = Int(50.0 * (270.0 - torsoAngle) / 150.0)
        } else {
            s1 = 0
        }

        // 設計書基準 - 左肘（extensionAngle）: 170°~180° → 50点
        // - 曲がりすぎ 0°~169.9° → 50×(θ/170)
        let s2: Int
        if (170...180).contains(normalizedExtension) {
            s2 = 50
        } else if normalizedExtension < 170 {
            // 曲がりすぎ
            s2 = Int(50.0 * normalizedExtension / 170.0)
        } else {
            // 180°を超える場合（正規化後はありえないが）
            s2 = 50
        }
        
        // 最終スコア = 左肩スコア + 左肘スコア
        return s1 + s2
    }

    // MARK: - 5) 体軸傾き（腰角/膝角の偏差平均）
    private static func scoreBodyAxisTilt(_ deltaDeg: Double) -> Int {
        // 🔧 設計書準拠:
        // - 理想範囲 Δθ ≤ 5° → 100点
        // - 折れが大きい 5° < Δθ ≤ 60° : 100×((60−Δθ)/55)
        // - 最低レベル 60° < Δθ : 0点
        
        if deltaDeg <= 5 {
            return 100
        } else if deltaDeg <= 60 {
            return Int(100.0 * (60.0 - deltaDeg) / 55.0)
        } else {
            return 0
        }
    }

    // MARK: - 6) ラケット面（Yaw/Pitch）
    private static func estimateRacketFace(
        imuHistory: [ServeSample],
        impactMs: Int64,
        calibration: CalibrationResult?
    ) -> (yaw: Double, pitch: Double, flag: String?) {
        // キャリブなし：Impact前後±60ms の gy を yaw、gx を pitch として微小角近似
        guard !imuHistory.isEmpty else { return (0, 0, "no_imu_for_racket_face") }
        if calibration == nil {
            let winStart = impactMs - 60, winEnd = impactMs + 20
            let win = imuHistory.filter { $0.monotonic_ms >= winStart && $0.monotonic_ms <= winEnd }
            guard win.count >= 3 else { return (0, 0, "short_imu_window_for_racket_face") }
            // 角速度[rad/s] が gy/gx で来ている前提 → dt 積分 → deg
            var yawRad = 0.0, pitchRad = 0.0
            for i in 1..<win.count {
                let dt = Double(win[i].monotonic_ms - win[i-1].monotonic_ms) / 1000.0
                yawRad   += win[i].gy * dt
                pitchRad += win[i].gx * dt
            }
            return (yawRad * 180.0 / .pi, pitchRad * 180.0 / .pi, "approx_racket_face_no_calib")
        }
        // TODO: calibration を用いた正しい姿勢推定（Phase 2で実装）
        return (0, 0, "racket_face_needs_calibration")
    }

    private static func scoreRacketFace(yaw: Double, pitch: Double) -> Int {
        // 🔧 設計書準拠: ロール（yaw相当）とピッチ
        
        // ロール（yaw）の評価
        // - 理想範囲 -5°~+5° → 50点
        // - 左/右に傾きすぎ -60°~-5.1° または +5.1°~+60° : 50×((60−|r|)/55)
        // - 最低レベル |r|>60° : 0点
        let sYaw: Int
        let absYaw = abs(yaw)
        if absYaw <= 5 {
            sYaw = 50
        } else if absYaw <= 60 {
            sYaw = Int(50.0 * (60.0 - absYaw) / 55.0)
        } else {
            sYaw = 0
        }

        // ピッチの評価
        // - 理想範囲 -10°~+10° → 50点
        // - 下/上向きすぎ -60°~-10.1° または +10.1°~+60° : 50×((50−|p|)/50)
        // - 最低レベル |p|>60° : 0点
        let sPitch: Int
        let absPitch = abs(pitch)
        if absPitch <= 10 {
            sPitch = 50
        } else if absPitch <= 60 {
            sPitch = Int(50.0 * (50.0 - (absPitch - 10.0)) / 50.0)
        } else {
            sPitch = 0
        }

        // 最終スコア = ロールスコア + ピッチスコア
        return sYaw + sPitch
    }

    // MARK: - 7) トス前方距離[m]
    private static func estimateTossForwardDistance(
        tossHistory: [BallDetection],
        poseRef: PoseData,
        courtCalib: CourtCalibration?
    ) -> (Double, String?) {
        guard let apex = tossHistory.max(by: { $0.position.y < $1.position.y }) else {
            return (0.0, "no_toss_apex")
        }
        if let cc = courtCalib {
            // Phase 2: ホモグラフィで z=0 へ投影して前方距離を算出
            // ここでは API だけ合わせ、実装は CourtCalibration 側のメソッドを想定
            if let meters = cc.projectForwardDistanceToBaseline(pixelPoint: apex.position) {
                return (meters, nil)
            } else {
                return (0.0, "court_calib_projection_failed")
            }
        } else {
            // 暫定：画面座標の基準（肩中点）からの x 差を画面幅で規格化→係数0.8m換算
            guard let ls = poseRef.joints[.leftShoulder], let rs = poseRef.joints[.rightShoulder] else {
                return (0.0, "no_shoulders_for_toss_approx")
            }
            let shoulderMidX = (ls.x + rs.x) / 2.0
            let dx = Double(apex.position.x - shoulderMidX)
            let ratio = dx / Double(poseRef.imageSize.width) // [-1,1]程度
            return (ratio * 0.8, "approx_toss_no_homography")
        }
    }

    private static func scoreTossForward(_ meters: Double) -> Int {
        // 目安：0.2–0.6m 前方を高評価（スイング方向への前進）
        let a = abs(meters)
        if (0.2...0.6).contains(a) { return 100 }
        if (0.1..<0.2).contains(a)  { return lerp(from: 70, to: 100, x: (a-0.1)/0.1) }
        if (0.6..<0.8).contains(a)  { return lerp(from: 100, to: 70, x: (a-0.6)/0.2) }
        if (0.05..<0.1).contains(a) { return lerp(from: 40, to: 70, x: (a-0.05)/0.05) }
        if (0.8..<1.0).contains(a)  { return lerp(from: 70, to: 40, x: (a-0.8)/0.2) }
        if a < 0.05 { return max(0, Int(40 * a / 0.05)) }
        return max(0, Int(40 - (a - 1.0) / 0.5 * 40))
    }

    // MARK: - 8) リストワーク（回内外の合計角度）
    private static func estimateWristRotationDeg(
        imuHistory: [ServeSample],
        startMs: Int64,
        endMs: Int64
    ) -> Double {
        // gyroscope の gz を回外/回内の主成分とみなして小窓積分（近似）
        guard !imuHistory.isEmpty else { return 0.0 }
        let win = imuHistory.filter { $0.monotonic_ms >= startMs && $0.monotonic_ms <= endMs }
        guard win.count >= 3 else { return 0.0 }
        var rad = 0.0
        for i in 1..<win.count {
            let dt = Double(win[i].monotonic_ms - win[i-1].monotonic_ms) / 1000.0
            rad += abs(win[i].gz) * dt
        }
        return rad * 180.0 / .pi
    }

    private static func scoreWristwork(_ deg: Double) -> Int {
        // 目安：総回転 120–220° が高評価（不足/過多は減点）
        if (120...220).contains(deg) { return 100 }
        if (90..<120).contains(deg)  { return lerp(from: 70, to: 100, x: (deg-90)/30) }
        if (220..<280).contains(deg) { return lerp(from: 100, to: 70, x: (deg-220)/60) }
        if (60..<90).contains(deg)   { return lerp(from: 40, to: 70, x: (deg-60)/30) }
        if (280..<360).contains(deg) { return lerp(from: 70, to: 40, x: (deg-280)/80) }
        if deg < 60 { return max(0, Int(40 * deg / 60)) }
        return max(0, Int(40 - (deg - 360) / 120 * 40))
    }

    // MARK: - Helpers
    private static func lerp(from: Int, to: Int, x: Double) -> Int {
        let t = max(0.0, min(1.0, x))
        return Int(round(Double(from) + (Double(to - from) * t)))
    }

    /*
    // ※現在は使用していません（単純平均に変更）
    private static func weightedTotal(_ scores: [Double], weights: [Double]) -> Double {
        guard scores.count == weights.count else { return 0 }
        let s = zip(scores, weights).reduce(0.0) { $0 + ($1.0 * $1.1 / 100.0) }
        return s
    }
    */
}

// --- Temporary stub for Phase 1 buildability ---
import CoreGraphics

extension CourtCalibration {
    /// トス頂点の画素座標をコート平面(z=0)へ射影し、ベースラインからの前方距離[m]を返す
    /// Phase 2で実装。本スタブは nil を返す。
    func projectForwardDistanceToBaseline(pixelPoint: CGPoint) -> Double? {
        return nil
    }
}
