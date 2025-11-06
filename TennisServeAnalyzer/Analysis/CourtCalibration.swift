//
//  CourtCalibration.swift
//  TennisServeAnalyzer
//
//  Created by 島本健生 on 2025/11/06.
//

//
//  CourtCalibration.swift
//  TennisServeAnalyzer
//
//  Court geometry calibration using homography
//

import Foundation
import Accelerate
import simd
import AVFoundation

struct CourtCalibrationResult {
    let homography: simd_float3x3
    let rotation: simd_float3x3
    let translation: simd_float3
    let cameraIntrinsics: simd_float3x3
    let timestamp: Date
}

class CourtCalibration: ObservableObject {
    // 実世界座標（メートル）
    // シングルスコート幅: 8.23m
    private let courtWidth: Float = 8.23
    
    // キャリブレーション点（画面座標）
    @Published var calibrationPoints: [CGPoint] = []
    private let requiredPoints = 4
    
    // カメラ内部パラメータ（AVFoundation取得）
    private var cameraIntrinsics: simd_float3x3?
    
    // 結果
    @Published var calibrationResult: CourtCalibrationResult?
    @Published var isCalibrated: Bool = false
    
    // MARK: - Public API
    
    /// キャリブレーション点を追加
    func addPoint(_ point: CGPoint) {
        guard calibrationPoints.count < requiredPoints else {
            print("⚠️ Already have 4 points")
            return
        }
        
        calibrationPoints.append(point)
        print("📍 Point \(calibrationPoints.count)/4 added: \(point)")
        
        if calibrationPoints.count == requiredPoints {
            performCalibration()
        }
    }
    
    /// リセット
    func reset() {
        calibrationPoints.removeAll()
        calibrationResult = nil
        isCalibrated = false
        print("🔄 Calibration reset")
    }
    
    /// トス位置の地面座標を計算
    func projectTossToGround(
        ballScreenPosition: CGPoint,
        imageSize: CGSize
    ) -> (x: Float, y: Float)? {
        guard let result = calibrationResult else {
            print("⚠️ Not calibrated")
            return nil
        }
        
        // 画面座標を正規化（0-1）
        let u = Float(ballScreenPosition.x / imageSize.width)
        let v = Float(ballScreenPosition.y / imageSize.height)
        
        // 正規化座標をカメラ座標系に変換
        let K_inv = result.cameraIntrinsics.inverse
        let normalized = simd_float3(u, v, 1.0)
        let ray = K_inv * normalized
        
        // レイと地面（z=0）の交点を計算
        // P_world = R^T * (λ*ray - t)
        // z_world = 0 → λを求める
        
        let R_inv = result.rotation.transpose
        let t = result.translation
        
        // z成分 = 0の条件から λ を求める
        // 0 = R_inv[2] * (λ*ray - t)
        // λ = (R_inv[2] * t) / (R_inv[2] * ray)
        
        let numerator = simd_dot(R_inv[2], t)
        let denominator = simd_dot(R_inv[2], ray)
        
        guard abs(denominator) > 0.001 else {
            print("⚠️ Ray parallel to ground")
            return nil
        }
        
        let lambda = numerator / denominator
        let P_camera = lambda * ray
        let P_world = R_inv * (P_camera - t)
        
        print("🎾 Toss ground position: x=\(P_world.x)m, y=\(P_world.y)m")
        
        return (x: P_world.x, y: P_world.y)
    }
    
    /// ベースラインからの前進距離を計算
    func distanceFromBaseline(tossPosition: (x: Float, y: Float)) -> Float {
        // ベースラインはy=0と仮定
        // 前進距離 = y座標（正の値がネット方向）
        return tossPosition.y
    }
    
    // MARK: - Private Methods
    
    private func performCalibration() {
        print("🔧 Performing calibration...")
        
        guard calibrationPoints.count == requiredPoints else {
            print("❌ Need exactly 4 points")
            return
        }
        
        // 実世界の4点座標を定義
        // Point 0: ベースライン左端 (0, 0)
        // Point 1: ベースライン右端 (8.23, 0)
        // Point 2: 1m前・左 (0, 1.0)
        // Point 3: 1m前・右 (8.23, 1.0)
        
        let worldPoints: [simd_float2] = [
            simd_float2(0.0, 0.0),
            simd_float2(courtWidth, 0.0),
            simd_float2(0.0, 1.0),
            simd_float2(courtWidth, 1.0)
        ]
        
        // 画面座標を正規化（0-1）
        let imageSize = CGSize(width: 1080, height: 1920)  // 縦動画
        let screenPoints = calibrationPoints.map { point in
            simd_float2(
                Float(point.x / imageSize.width),
                Float(point.y / imageSize.height)
            )
        }
        
        // ホモグラフィ行列を計算
        guard let H = computeHomography(
            from: screenPoints,
            to: worldPoints
        ) else {
            print("❌ Homography computation failed")
            return
        }
        
        // カメラ内部パラメータを取得（仮値 or AVFoundation）
        let K = getCameraIntrinsics()
        
        // H = K [r1 r2 t] を分解
        let (R, t) = decomposeHomography(H: H, K: K)
        
        // 結果を保存
        let result = CourtCalibrationResult(
            homography: H,
            rotation: R,
            translation: t,
            cameraIntrinsics: K,
            timestamp: Date()
        )
        
        DispatchQueue.main.async {
            self.calibrationResult = result
            self.isCalibrated = true
            print("✅ Calibration complete")
        }
    }
    
    /// ホモグラフィ行列計算（DLT法）
    private func computeHomography(
        from srcPoints: [simd_float2],
        to dstPoints: [simd_float2]
    ) -> simd_float3x3? {
        guard srcPoints.count == 4 && dstPoints.count == 4 else {
            return nil
        }
        
        // A * h = 0 の形式で方程式を構築（8x9行列）
        var A = [[Float]](repeating: [Float](repeating: 0, count: 9), count: 8)
        
        for i in 0..<4 {
            let x = srcPoints[i].x
            let y = srcPoints[i].y
            let u = dstPoints[i].x
            let v = dstPoints[i].y
            
            A[2*i] = [-x, -y, -1, 0, 0, 0, u*x, u*y, u]
            A[2*i+1] = [0, 0, 0, -x, -y, -1, v*x, v*y, v]
        }
        
        // SVD で最小固有値に対応する固有ベクトルを求める
        // （簡易実装：ここではAccelerateのSVDを使用）
        
        // 実際にはvDSP/Accelerateを使うが、簡略化のため仮実装
        // 本番では LAPACK の SVD を呼び出す
        
        let h = solveHomographySVD(A)
        
        let H = simd_float3x3(
            simd_float3(h[0], h[1], h[2]),
            simd_float3(h[3], h[4], h[5]),
            simd_float3(h[6], h[7], h[8])
        )
        
        return H
    }
    
    private func solveHomographySVD(_ A: [[Float]]) -> [Float] {
        // 簡易実装：Accelerate の svd_s を使用
        // 実運用では LAPACK の sgesvd を呼び出す
        
        // ここでは仮の値を返す（実装要）
        return [1, 0, 0, 0, 1, 0, 0, 0, 1]
    }
    
    /// H = K [r1 r2 t] の分解
    private func decomposeHomography(
        H: simd_float3x3,
        K: simd_float3x3
    ) -> (R: simd_float3x3, t: simd_float3) {
        // K^{-1} * H = [r1 r2 t]
        let K_inv = K.inverse
        let M = K_inv * H
        
        // r1, r2 を正規化して R を構築
        var r1 = M[0]
        var r2 = M[1]
        let t = M[2]
        
        r1 = simd_normalize(r1)
        r2 = simd_normalize(r2)
        let r3 = simd_cross(r1, r2)
        
        var R = simd_float3x3(r1, r2, r3)
        
        // R を直交行列に補正（SVD で最近傍直交行列を求める）
        R = orthogonalizeRotation(R)
        
        return (R: R, t: t)
    }
    
    private func orthogonalizeRotation(_ R: simd_float3x3) -> simd_float3x3 {
        // Gram-Schmidt 直交化（簡易版）
        var r1 = R[0]
        var r2 = R[1]
        var r3 = R[2]
        
        r1 = simd_normalize(r1)
        r2 = r2 - simd_dot(r2, r1) * r1
        r2 = simd_normalize(r2)
        r3 = simd_cross(r1, r2)
        
        return simd_float3x3(r1, r2, r3)
    }
    
    /// カメラ内部パラメータ取得（AVFoundation or 仮値）
    private func getCameraIntrinsics() -> simd_float3x3 {
        // AVFoundation から取得する場合
        // CMSampleBuffer の AVCameraCalibrationData を使用
        
        // 仮値（iPhone 14 Pro 相当）
        // 焦点距離 fx, fy ≈ 1200px（1080px幅の場合）
        // 主点 cx, cy ≈ (540, 960)
        
        let fx: Float = 1200.0
        let fy: Float = 1200.0
        let cx: Float = 540.0
        let cy: Float = 960.0
        
        return simd_float3x3(
            simd_float3(fx, 0, cx),
            simd_float3(0, fy, cy),
            simd_float3(0, 0, 1)
        )
    }
    
    /// AVFoundation からカメラ内部パラメータを取得（実装例）
    func updateCameraIntrinsicsFromSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMCopyDictionaryOfAttachments(
            allocator: kCFAllocatorDefault,
            target: sampleBuffer,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        ) as? [String: Any] else {
            return
        }
        
        // iOS 11.1+ で利用可能
        if let calibrationData = attachments[String(kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix)] as? Data {
            calibrationData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                if let baseAddress = ptr.baseAddress {
                    let matrix = baseAddress.assumingMemoryBound(to: Float.self)
                    
                    let fx = matrix[0]
                    let fy = matrix[4]
                    let cx = matrix[6]
                    let cy = matrix[7]
                    
                    cameraIntrinsics = simd_float3x3(
                        simd_float3(fx, 0, cx),
                        simd_float3(0, fy, cy),
                        simd_float3(0, 0, 1)
                    )
                    
                    print("📷 Camera intrinsics updated: fx=\(fx), fy=\(fy)")
                }
            }
        }
    }
}
