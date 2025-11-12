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
    public let pelvisRiseM: Double                  // 3: 下半身貢献度（Trophy→Impact直前20–30msの骨盤上昇）
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

// MARK: - Weights (sum = 100)
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
    static func calculateMetrics(
        trophyPose: TrophyPoseEvent,
        impactEvent: ImpactEvent,
        tossHistory: [BallDetection],
        imuHistory: [ServeSample],
        calibration: CalibrationResult? = nil,
        courtCalibration: CourtCalibration? = nil,
        impactPose: PoseData? = nil
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

        // ========= 3) 下半身貢献度（骨盤上昇[m]）=========
        // Trophy と Impact 付近の Pose が必要。なければフラグを立てて 0 扱い。
        let impactPoseResolved = impactPose ?? trophyPose.pose // フォールバック（※理想は Impact）
        var pelvisRiseM = pelvisRiseMeters(trophyPose.pose, impactPoseResolved)
        if impactPose == nil { flags.append("no_impact_pose_for_pelvisRise") }
        let score3 = scorePelvisRise(pelvisRiseM)

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

        // ========= 合計 =========
        let scores = [score1, score2, score3, score4, score5, score6, score7, score8]
        let total = weightedTotal(scores.map { Double($0) }, weights: METRIC_WEIGHTS)


        return ServeMetrics(
            elbowAngleDeg: elbowAngle,
            armpitAngleDeg: armpit,
            pelvisRiseM: pelvisRiseM,
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
        // 🔧 修正: 360°範囲を0°～180°に正規化
        let normalizedAngle = normalizeAngle(angle)
        
        // 🔧 修正: 基準値 90–110°
        switch normalizedAngle {
        case 90...110: return 100
        case 80..<90: return lerp(from: 70, to: 100, x: (normalizedAngle-80)/10)
        case 110..<120: return lerp(from: 100, to: 70, x: (normalizedAngle-110)/10)
        case 60..<80: return lerp(from: 40, to: 70, x: (normalizedAngle-60)/20)
        case 120..<140: return lerp(from: 70, to: 40, x: (normalizedAngle-120)/20)
        case ..<60:    return max(0, Int(40 * normalizedAngle / 60))
        default:        return max(0, Int(40 - (normalizedAngle - 140) / 40 * 40))
        }
    }

    // MARK: - 2) 脇角（上腕-体幹の外角）
    private static func scoreArmpitAngle(_ angle: Double) -> Int {
        // 🔧 修正: 360°対応 - 基準値 170–190°
        // 360°スケールではそのまま使用（正規化しない）
        
        if (170...190).contains(angle) { return 100 }
        if (160..<170).contains(angle) { return lerp(from: 70, to: 100, x: (angle-160)/10) }
        if (190..<200).contains(angle) { return lerp(from: 100, to: 70, x: (angle-190)/10) }
        if (140..<160).contains(angle) { return lerp(from: 40, to: 70, x: (angle-140)/20) }
        if (200..<220).contains(angle) { return lerp(from: 70, to: 40, x: (angle-200)/20) }
        if angle < 140 { return max(0, Int(40 * angle / 140)) }
        return max(0, Int(40 - (angle - 220)/50 * 40))
    }

    // MARK: - 3) 下半身貢献度（骨盤上昇）
    private static func pelvisRiseMeters(_ trophy: PoseData, _ impact: PoseData) -> Double {
        // 右/左 Hip の中点のY差を画素→相対→mへ換算
        guard let rH = trophy.joints[.rightHip], let lH = trophy.joints[.leftHip],
              let rA = trophy.joints[.rightAnkle], let lA = trophy.joints[.leftAnkle],
              let rH2 = impact.joints[.rightHip], let lH2 = impact.joints[.leftHip] else {
            return 0.0
        }
        let hipMid1 = CGPoint(x: (rH.x + lH.x)/2, y: (rH.y + lH.y)/2)
        let hipMid2 = CGPoint(x: (rH2.x + lH2.x)/2, y: (rH2.y + lH2.y)/2)

        // 画素→身長スケーリング：股関節-足首距離を 0.53H とみなして相対尺度化
        let pixLeg = (hypot(rH.x-rA.x, rH.y-rA.y) + hypot(lH.x-lA.x, lH.y-lA.y)) / 2.0
        guard pixLeg > 0 else { return 0.0 }

        let pixRise = max(0.0, hipMid1.y - hipMid2.y) // 上昇は画面座標で y 減少
        let riseToLeg = Double(pixRise / pixLeg)      // 下肢長比
        // 成人平均下肢長 ≈ 0.9m（概算）→ m換算（キャリブなしの一時実装）
        return riseToLeg * 0.9
    }

    private static func scorePelvisRise(_ meters: Double) -> Int {
        // 設計：0.12–0.25m で高評価
        if (0.12...0.25).contains(meters) { return 100 }
        if (0.08..<0.12).contains(meters) { return lerp(from: 70, to: 100, x: (meters-0.08)/0.04) }
        if (0.25..<0.32).contains(meters) { return lerp(from: 100, to: 70, x: (meters-0.25)/0.07) }
        if (0.04..<0.08).contains(meters) { return lerp(from: 40, to: 70, x: (meters-0.04)/0.04) }
        if (0.32..<0.40).contains(meters) { return lerp(from: 70, to: 40, x: (meters-0.32)/0.08) }
        if meters < 0.04 { return max(0, Int(40 * meters / 0.04)) }
        return max(0, Int(40 - (meters - 0.40)/0.20 * 40))
    }

    // MARK: - 4) 左手位置（体幹-左腕 & 上腕-前腕の2角度の合成）
    private static func scoreLeftHandPosition(torsoAngle: Double, extensionAngle: Double) -> Int {
        // 🔧 修正: 左肩（torsoAngle）は360°対応、左肘（extensionAngle）は180°のまま
        // torsoAngle: 360°スケール、正規化しない
        // extensionAngle: 180°スケール、正規化する
        let normalizedExtension = normalizeAngle(extensionAngle)
        
        // 🔧 修正: torsoAngle（左肩）基準値 90–110°（真上） - 360°対応
        let s1: Int
        if (90...110).contains(torsoAngle) { s1 = 100 }
        else if (80..<90).contains(torsoAngle) { s1 = lerp(from: 70, to: 100, x: (torsoAngle-80)/10) }
        else if (110..<120).contains(torsoAngle) { s1 = lerp(from: 100, to: 70, x: (torsoAngle-110)/10) }
        else if (60..<80).contains(torsoAngle) { s1 = lerp(from: 40, to: 70, x: (torsoAngle-60)/20) }
        else if (120..<140).contains(torsoAngle) { s1 = lerp(from: 70, to: 40, x: (torsoAngle-120)/20) }
        else if torsoAngle < 60 { s1 = max(0, Int(40 * torsoAngle / 60)) }
        else { s1 = max(0, Int(40 - (torsoAngle - 140)/130 * 40)) }

        // 🔧 修正: extensionAngle（左肘）基準値 170–180°（伸展）
        let s2: Int
        if (170...180).contains(normalizedExtension) { s2 = 100 }
        else if (160..<170).contains(normalizedExtension) { s2 = lerp(from: 70, to: 100, x: (normalizedExtension-160)/10) }
        else if (150..<160).contains(normalizedExtension) { s2 = lerp(from: 40, to: 70, x: (normalizedExtension-150)/10) }
        else if normalizedExtension < 150 { s2 = max(0, Int(40 * normalizedExtension / 150)) }
        else { s2 = max(0, Int(40 - (normalizedExtension - 180) / 20 * 40)) }
        
        return Int((Double(s1) * 0.5) + (Double(s2) * 0.5))
    }

    // MARK: - 5) 体軸傾き（腰角/膝角の偏差平均）
    private static func scoreBodyAxisTilt(_ deltaDeg: Double) -> Int {
        // ideal: Δθ ≤ 5°
        if deltaDeg <= 5 { return 100 }
        if deltaDeg <= 10 { return lerp(from: 70, to: 100, x: (10 - deltaDeg)/5) }
        if deltaDeg <= 20 { return lerp(from: 40, to: 70, x: (20 - deltaDeg)/10) }
        if deltaDeg <= 35 { return lerp(from: 10, to: 40, x: (35 - deltaDeg)/15) }
        return 0
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
        // 目安：Impact 時に yaw ≈ 0±15°, pitch ≈ 0±10° を高評価
        let sYaw: Int
        let ay = abs(yaw)
        if ay <= 15 { sYaw = 100 }
        else if ay <= 30 { sYaw = lerp(from: 70, to: 100, x: (30 - ay)/15) }
        else if ay <= 50 { sYaw = lerp(from: 40, to: 70, x: (50 - ay)/20) }
        else { sYaw = 20 }

        let sPitch: Int
        let ap = abs(pitch)
        if ap <= 10 { sPitch = 100 }
        else if ap <= 20 { sPitch = lerp(from: 70, to: 100, x: (20 - ap)/10) }
        else if ap <= 35 { sPitch = lerp(from: 40, to: 70, x: (35 - ap)/15) }
        else { sPitch = 20 }

        return Int((Double(sYaw) + Double(sPitch)) / 2.0)
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

    private static func weightedTotal(_ scores: [Double], weights: [Double]) -> Double {
        guard scores.count == weights.count else { return 0 }
        let s = zip(scores, weights).reduce(0.0) { $0 + ($1.0 * $1.1 / 100.0) }
        return s
    }
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
