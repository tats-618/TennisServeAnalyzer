//
//  ServeAnalyzer.swift
//  TennisServeAnalyzer Watch App
//
//  IMU data collection and transmission to iPhone
//

import Foundation
import CoreMotion
import Combine

class ServeAnalyzer: ObservableObject {
    // MARK: Properties
    @Published var collectionState: DataCollectionState = .idle
    @Published var currentSampleCount: Int = 0
    @Published var isRecording: Bool = false
    
    private let motionManager = CMMotionManager()
    private var collectedData: [ServeSample] = []
    private var startTime: Date?
    
    // Configuration
    private let sampleRate: Double = 100.0  // 100Hz (reduced from 200Hz for better connectivity)
    private let maxSamples: Int = 2000
    private let batchSize: Int = 50  // Send in batches of 50 samples
    
    // Watch connectivity
    private let watchManager = WatchConnectivityManager.shared
    
    // MARK: - Initialization
    init() {
        print("⌚ ServeAnalyzer init")
        setupMotionManager()
    }
    
    private func setupMotionManager() {
        guard motionManager.isDeviceMotionAvailable else {
            print("❌ Device Motion not available")
            return
        }
        
        motionManager.deviceMotionUpdateInterval = 1.0 / sampleRate
        print("✅ Motion manager configured: \(sampleRate)Hz")
    }
    
    // MARK: - Recording Control
    func startRecording() {
        print("🎬 Starting Watch recording...")
        
        guard !isRecording else {
            print("⚠️ Already recording")
            return
        }
        
        // Reset
        collectedData.removeAll()
        currentSampleCount = 0
        startTime = Date()
        
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
        
        print("✅ Watch recording stopped - collected \(currentSampleCount) samples")
    }
    
    // MARK: - Motion Data Processing
    private func processMotionData(_ motion: CMDeviceMotion) {
        let timestamp = Date()
        let monotonicMs = Int64(timestamp.timeIntervalSince1970 * 1000)
        
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
    
    // MARK: - Data Transmission
    private func sendBatchToiPhone(_ samples: [ServeSample], final: Bool) {
        var flags: [String] = ["watch_imu", "rate:\(Int(sampleRate))hz"]
        
        if final {
            flags.append("final_batch")
        }
        
        watchManager.sendBatchData(samples, flags: flags)
        
        if samples.count >= 50 || final {
            print("📤 Sent batch: \(samples.count) samples (total: \(currentSampleCount))")
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
        currentSampleCount = 0
        startTime = nil
        collectionState = .idle
    }
}
