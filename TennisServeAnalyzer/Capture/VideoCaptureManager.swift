//
//  VideoCaptureManager.swift
//  TennisServeAnalyzer
//
//  Camera capture system for tennis serve analysis
//  - 120fps vertical video (1080p)
//  - EXIF orientation handling
//  - Real-time frame processing
//  - Timestamp synchronization with Watch
//

import AVFoundation
import CoreMedia
import UIKit

// MARK: - Delegate Protocol
protocol VideoCaptureDelegate: AnyObject {
    func videoCaptureDidOutput(sampleBuffer: CMSampleBuffer, timestamp: Double)
    func videoCaptureDidFail(error: Error)
    func videoCaptureDidStart()
    func videoCaptureDidStop()
}

// MARK: - Video Capture Manager
class VideoCaptureManager: NSObject, ObservableObject {
    // MARK: Properties
    weak var delegate: VideoCaptureDelegate?
    
    @Published var isRecording: Bool = false
    @Published var currentFPS: Double = 0.0
    @Published var droppedFrames: Int = 0
    
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    
    private let videoQueue = DispatchQueue(
        label: "com.tennisanalyzer.videoqueue",
        qos: .userInitiated
    )
    
    // Frame timing
    private var frameCount: Int = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var recordingStartTime: CFTimeInterval = 0
    
    // Configuration
    private let targetFPS: Int = 120  // Target frame rate
    private let targetResolution = CMVideoDimensions(width: 1080, height: 1920)  // Vertical
    
    // MARK: - Initialization
    override init() {
        super.init()
        setupCaptureSession()
    }
    
    // MARK: - Setup
    private func setupCaptureSession() {
        captureSession = AVCaptureSession()
        
        guard let session = captureSession else {
            print("❌ Failed to create capture session")
            return
        }
        
        session.beginConfiguration()
        
        // Set session preset
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        
        // Setup video device (back camera)
        guard let videoDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            print("❌ No video device available")
            session.commitConfiguration()
            return
        }
        
        self.videoDevice = videoDevice
        
        // Configure device for 120fps
        do {
            try configureDevice(videoDevice)
        } catch {
            print("❌ Failed to configure device: \(error)")
        }
        
        // Add video input
        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(input) {
                session.addInput(input)
                self.videoInput = input
                print("✅ Video input added")
            }
        } catch {
            print("❌ Failed to create video input: \(error)")
        }
        
        // Add video output
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: videoQueue)
        output.alwaysDiscardsLateVideoFrames = true
        
        // Set pixel format (420YpCbCr8BiPlanarFullRange for best performance)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        
        if session.canAddOutput(output) {
            session.addOutput(output)
            self.videoOutput = output
            
            // Set video orientation to portrait
            if let connection = output.connection(with: .video) {
                // iOS 17+ uses videoRotationAngle
                if #available(iOS 17.0, *) {
                    if connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90  // Portrait
                    }
                } else {
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }
                }
                
                // Disable video stabilization for higher FPS
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .off
                }
            }
            
            print("✅ Video output added")
        }
        
        session.commitConfiguration()
        print("✅ Capture session configured (target: \(targetFPS)fps)")
    }
    
    private func configureDevice(_ device: AVCaptureDevice) throws {
            try device.lockForConfiguration()
            
            print("🔍 Searching for 120fps format...")
            print("   Available formats: \(device.formats.count)")
            
            // Find 120fps format
            var bestFormat: AVCaptureDevice.Format?
            var bestFrameRate: Float64 = 0
            
            for (index, format) in device.formats.enumerated() {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                
                // Look for format with sufficient resolution (portrait or landscape)
                let minDimension = min(dimensions.width, dimensions.height)
                let maxDimension = max(dimensions.width, dimensions.height)
                
                // Accept any format with at least 720p (1280x720) that supports 120fps
                if minDimension >= 720 && maxDimension >= 1280 {
                    for range in format.videoSupportedFrameRateRanges {
                        if range.maxFrameRate >= Double(targetFPS) {
                            if range.maxFrameRate > bestFrameRate {
                                bestFormat = format
                                bestFrameRate = range.maxFrameRate
                                print("   Format \(index): \(dimensions.width)x\(dimensions.height) @ \(range.maxFrameRate)fps ✓")
                            }
                        }
                    }
                }
            }
            
            if let format = bestFormat {
                device.activeFormat = format
                
                // Set frame rate to 120fps
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                print("✅ Video format set: \(dims.width)x\(dims.height) @ \(bestFrameRate)fps")
            } else {
                print("⚠️ 120fps format not available, using default")
                
                // Fallback to highest available FPS
                if let format = device.formats.first {
                    device.activeFormat = format
                    if let maxRate = format.videoSupportedFrameRateRanges.first {
                        let maxFPS = Int(maxRate.maxFrameRate)
                        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(maxFPS))
                        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(maxFPS))
                        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        print("⚠️ Using fallback: \(dims.width)x\(dims.height) @ \(maxFPS)fps")
                    }
                }
            }
            
            // Auto exposure and focus
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            
            device.unlockForConfiguration()
        }
    
    // MARK: - Recording Control
    func startRecording() {
        guard let session = captureSession, !isRecording else { return }
        
        print("🎬 Starting video capture...")
        
        // Reset counters
        frameCount = 0
        droppedFrames = 0
        recordingStartTime = CACurrentMediaTime()
        lastFrameTime = recordingStartTime
        
        videoQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Stop session if running
            if session.isRunning {
                print("⏸ Stopping existing session...")
                session.stopRunning()
            }
            
            // Reconfigure device to ensure 120fps is active
            if let device = self.videoDevice {
                print("🔧 Reconfiguring device for 120fps...")
                do {
                    try self.configureDevice(device)
                    print("✅ Device reconfigured")
                } catch {
                    print("⚠️ Failed to reconfigure: \(error)")
                }
            }
            
            // Start session
            print("▶️ Starting session...")
            session.startRunning()
            
            // Verify FPS after starting
            if let device = self.videoDevice {
                let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                let fps = device.activeVideoMaxFrameDuration
                let actualFPS = Double(fps.timescale) / Double(fps.value)
                print("📹 Active format: \(dims.width)x\(dims.height) @ \(actualFPS)fps")
            }
            
            DispatchQueue.main.async {
                self.isRecording = true
                self.delegate?.videoCaptureDidStart()
                print("✅ Video capture started")
            }
        }
    }
    
    func stopRecording() {
        guard let session = captureSession, isRecording else { return }
        
        print("⏹ Stopping video capture...")
        
        videoQueue.async { [weak self] in
            session.stopRunning()
            
            DispatchQueue.main.async {
                self?.isRecording = false
                self?.delegate?.videoCaptureDidStop()
                
                let duration = CACurrentMediaTime() - (self?.recordingStartTime ?? 0)
                let avgFPS = Double(self?.frameCount ?? 0) / duration
                
                print("✅ Video capture stopped")
                print("📊 Stats: \(self?.frameCount ?? 0) frames in \(String(format: "%.1f", duration))s")
                print("📊 Average FPS: \(String(format: "%.1f", avgFPS))")
                print("📊 Dropped frames: \(self?.droppedFrames ?? 0)")
            }
        }
    }
    
    // MARK: - Preview Layer
    func createPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        guard let session = captureSession else { return nil }
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        
        return previewLayer
    }
    
    // MARK: - Utility
    func requestCameraPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        default:
            completion(false)
        }
    }
    
    // MARK: - Cleanup
    deinit {
        stopRecording()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension VideoCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Update frame count
        frameCount += 1
        
        // Calculate FPS
        let currentTime = CACurrentMediaTime()
        let deltaTime = currentTime - lastFrameTime
        lastFrameTime = currentTime
        
        if deltaTime > 0 {
            let instantFPS = 1.0 / deltaTime
            
            // Update FPS on main thread (smoothed)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.currentFPS = self.currentFPS * 0.9 + instantFPS * 0.1  // EMA smoothing
            }
        }
        
        // Get presentation timestamp (relative to recording start)
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = CMTimeGetSeconds(presentationTime)
        
        // Notify delegate
        delegate?.videoCaptureDidOutput(sampleBuffer: sampleBuffer, timestamp: timestamp)
    }
    
    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        droppedFrames += 1
        
        if droppedFrames % 10 == 0 {
            //print("⚠️ Dropped frames: \(droppedFrames)")
        }
    }
}
