//
//  ServeAnalyzer.swift
//  TennisServeAnalyzer Watch App
//
//  IMU data collection and transmission to iPhone
//  Updated: 200Hz sampling rate for better precision
//

import Foundation
import CoreMotion
import Combine

class ServeAnalyzer: ObservableObject {
    // MARK: Properties
    @Published var collectionState: DataCollectionState = .idle
    @Published var currentSampleCount: Int = 0
    @Published var isRecording: Bool = false
    @Published var effectiveSampleRate: Double = 0.0  // ✅ 追加：実効Hz表示
    
    private let motionManager = CMMotionManager()
    private var collectedData: [ServeSample] = []
    private var startTime: Date?
    
    // Configuration
    private let sampleRate: Double = 200.0  // ✅ 変更：100.0 → 200.0
    private let maxSamples: Int = 4000      // ✅ 変更：2000 → 4000（200Hz * 20秒）
    private let batchSize: Int = 100        // ✅ 変更：50 → 100（0.5秒分）
    
    // Watch connectivity
    private let watchManager = WatchConnectivityManager.shared
    
    // Rate monitoring
    private var lastSampleTime: TimeInterval = 0
    private var sampleIntervals: [TimeInterval] = []
    
    // MARK: - Initialization
    init() {
        print("⌚ ServeAnalyzer init (200Hz mode)")
        setupMotionManager()
    }
    
    private func setupMotionManager() {
        guard motionManager.isDeviceMotionAvailable else {
            print("❌ Device Motion not available")
            return
        }
        
        motionManager.deviceMotionUpdateInterval = 1.0 / sampleRate  // 5ms
        print("✅ Motion manager configured: \(sampleRate)Hz (interval: \(motionManager.deviceMotionUpdateInterval * 1000)ms)")
    }
    
    // MARK: - Recording Control
    func startRecording() {
        print("🎬 Starting Watch recording at \(sampleRate)Hz...")
        
        guard !isRecording else {
            print("⚠️ Already recording")
            return
        }
        
        // Reset
        collectedData.removeAll()
        sampleIntervals.removeAll()
        currentSampleCount = 0
        startTime = Date()
        lastSampleTime = 0
        
        // Update state
        isRecording = true
        collectionState = .collecting
        
        // Start motion updates
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self = self, let motion = motion else {
                if let error = error {
                    print("❌ Motion error: \(error.localizedDescription)")
                }
                return
            }
            
            self.processMotionData(motion)
        }
        
        // Start rate monitoring
        scheduleRateCheck()
        
        print("✅ Watch recording started")
    }
    
    func stopRecording() {
        print("⏹ Stopping Watch recording...")
        
        guard isRecording else {
            print("⚠️ Not recording")
            return
        }
        
        motionManager.stopDeviceMotionUpdates()
        
        isRecording = false
        collectionState = .completed
        
        // Send remaining data
        if !collectedData.isEmpty {
            sendBatchToiPhone(collectedData, final: true)
        }
        
        // Calculate final stats
        let duration = startTime.map { -$0.timeIntervalSinceNow } ?? 0
        let avgHz = duration > 0 ? Double(currentSampleCount) / duration : 0
        
        print("✅ Watch recording stopped")
        print("📊 Total samples: \(currentSampleCount)")
        print("📊 Duration: \(String(format: "%.1f", duration))s")
        print("📊 Average rate: \(String(format: "%.1f", avgHz))Hz")
        print("📊 Target rate: \(sampleRate)Hz")
        
        // Update effective rate
        DispatchQueue.main.async { [weak self] in
            self?.effectiveSampleRate = avgHz
        }
    }
    
    // MARK: - Motion Data Processing
    private func processMotionData(_ motion: CMDeviceMotion) {
        let timestamp = Date()
        let currentTime = timestamp.timeIntervalSinceReferenceDate
        let monotonicMs = Int64(timestamp.timeIntervalSince1970 * 1000)
        
        // Track intervals for rate calculation
        if lastSampleTime > 0 {
            let interval = currentTime - lastSampleTime
            sampleIntervals.append(interval)
            
            // Keep last 100 intervals
            if sampleIntervals.count > 100 {
                sampleIntervals.removeFirst()
            }
        }
        lastSampleTime = currentTime
        
        // Extract acceleration (user acceleration + gravity)
        let accel = motion.userAcceleration
        let gravity = motion.gravity
        let totalAccel = (
            x: accel.x + gravity.x,
            y: accel.y + gravity.y,
            z: accel.z + gravity.z
        )
        
        // Extract gyroscope
        let gyro = motion.rotationRate
        
        // Create sample
        let sample = ServeSample(
            timestamp: timestamp,
            monotonicMs: monotonicMs,
            acceleration: (totalAccel.x, totalAccel.y, totalAccel.z),
            gyroscope: (gyro.x, gyro.y, gyro.z)
        )
        
        // Store sample
        collectedData.append(sample)
        
        DispatchQueue.main.async { [weak self] in
            self?.currentSampleCount += 1
        }
        
        // Send in batches for real-time processing
        if collectedData.count >= batchSize {
            let batch = Array(collectedData.prefix(batchSize))
            collectedData.removeFirst(batchSize)
            sendBatchToiPhone(batch, final: false)
        }
        
        // Limit total samples
        if currentSampleCount >= maxSamples {
            print("⚠️ Reached max samples, stopping...")
            DispatchQueue.main.async { [weak self] in
                self?.stopRecording()
            }
        }
    }
    
    // MARK: - Rate Monitoring
    private func scheduleRateCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, self.isRecording else { return }
            
            self.checkEffectiveRate()
            self.scheduleRateCheck()  // Repeat every 5 seconds
        }
    }
    
    private func checkEffectiveRate() {
        guard !sampleIntervals.isEmpty else { return }
        
        let avgInterval = sampleIntervals.reduce(0, +) / Double(sampleIntervals.count)
        let effectiveHz = avgInterval > 0 ? 1.0 / avgInterval : 0
        
        DispatchQueue.main.async { [weak self] in
            self?.effectiveSampleRate = effectiveHz
        }
        
        print("📊 Effective rate: \(String(format: "%.1f", effectiveHz))Hz (target: \(sampleRate)Hz)")
        
        // Warn if rate is significantly below target
        if effectiveHz < sampleRate * 0.9 {
            print("⚠️ Sample rate below 90% of target!")
        }
    }
    
    // MARK: - Data Transmission
    private func sendBatchToiPhone(_ samples: [ServeSample], final: Bool) {
        var flags: [String] = ["watch_imu", "rate:\(Int(sampleRate))hz"]
        
        if final {
            flags.append("final_batch")
        }
        
        // Add effective rate flag
        if effectiveSampleRate > 0 && effectiveSampleRate < sampleRate * 0.9 {
            flags.append("low_sample_rate:\(Int(effectiveSampleRate))hz")
        }
        
        watchManager.sendBatchData(samples, flags: flags)
        
        if samples.count >= 50 || final {
            print("📤 Sent batch: \(samples.count) samples (total: \(currentSampleCount), rate: \(String(format: "%.0f", effectiveSampleRate))Hz)")
        }
    }
    
    // MARK: - Analysis (Basic)
    func analyzeCollectedData() -> ServeAnalysis? {
        guard !collectedData.isEmpty else {
            print("⚠️ No data to analyze")
            return nil
        }
        
        // Calculate basic metrics
        var maxAccel: Double = 0.0
        var maxGyro: Double = 0.0
        
        for sample in collectedData {
            let accelMag = sqrt(
                sample.ax * sample.ax +
                sample.ay * sample.ay +
                sample.az * sample.az
            )
            
            let gyroMag = sqrt(
                sample.gx * sample.gx +
                sample.gy * sample.gy +
                sample.gz * sample.gz
            )
            
            maxAccel = max(maxAccel, accelMag)
            maxGyro = max(maxGyro, gyroMag)
        }
        
        let duration = startTime.map { -$0.timeIntervalSinceNow } ?? 0
        let swingSpeed = maxGyro * 0.25  // Estimate
        
        return ServeAnalysis(
            maxAcceleration: maxAccel,
            maxAngularVelocity: maxGyro,
            estimatedSwingSpeed: swingSpeed,
            duration: duration,
            recordedAt: Date()
        )
    }
    
    // MARK: - Reset
    func reset() {
        print("🔄 Resetting ServeAnalyzer")
        
        if isRecording {
            stopRecording()
        }
        
        collectedData.removeAll()
        sampleIntervals.removeAll()
        currentSampleCount = 0
        startTime = nil
        collectionState = .idle
        effectiveSampleRate = 0.0
    }
}
