# 🎾 Tennis Serve Analyzer

AI-powered tennis serve analysis app using iPhone camera and Apple Watch sensors.

## 📱 Overview

Tennis Serve Analyzer is an iOS application that provides comprehensive biomechanical analysis of tennis serves. It combines 120fps video capture with real-time pose detection and Apple Watch IMU data to deliver detailed performance metrics and improvement suggestions.

## ✨ Features

### Core Functionality
- 🎥 **120fps High-Speed Recording** - Capture every detail of your serve motion
- 🦴 **Real-time Skeleton Detection** - Live pose overlay using Vision Framework
- ⌚ **Apple Watch Integration** - 100Hz IMU data collection (accelerometer + gyroscope)
- 🏆 **Trophy Pose Detection** - Automatic identification of optimal serve position
- 💥 **Impact Detection** - Precise ball contact timing using sensor fusion
- 📊 **7-Metric Scoring System** - Comprehensive biomechanical evaluation

### Analysis Metrics

| Metric | Description | Weight |
|--------|-------------|--------|
| 1. Toss Stability | Consistency of ball toss height | 15% |
| 2. Shoulder-Pelvis Tilt | Upper body lean angle | 15% |
| 3. Knee Flexion | Leg drive measurement | 15% |
| 4. Elbow Angle | Arm extension in trophy pose | 10% |
| 5. Racket Drop | Back-scratch position depth | 15% |
| 6. Trunk Rotation Timing | Core rotation coordination | 15% |
| 7. Toss-to-Impact Timing | Overall serve rhythm | 15% |

## 🛠️ Technical Stack

### iOS App
- **Language**: Swift 5.9
- **Framework**: SwiftUI
- **Minimum iOS**: 17.0
- **Key Technologies**:
  - AVFoundation (120fps Video Capture)
  - Vision Framework (Pose Detection)
  - CoreImage (Image Processing)
  - Accelerate (FFT Analysis)

### Apple Watch
- **Language**: Swift 5.9
- **Sensors**: Accelerometer, Gyroscope (100Hz)
- **Minimum watchOS**: 10.0

## 📂 Project Structure

```
TennisServeAnalyzer/
├── Shared/
│   └── ServeDataModel.swift          # Data structures
├── Capture/
│   ├── VideoCaptureManager.swift     # Camera control
│   └── VideoAnalyzer.swift           # Analysis engine
├── Detection/
│   ├── PoseDetector.swift            # Skeleton detection
│   ├── EventDetector.swift           # Event detection
│   └── MetricsCalculator.swift       # Scoring
├── Views/
│   ├── ContentView.swift             # Main UI
│   └── PoseOverlayView.swift         # Skeleton overlay
└── Watch/
    └── MotionManager.swift           # IMU collection
```

## 🚀 Getting Started

### Prerequisites
- Xcode 15.0+
- iOS device (iOS 17.0+)
- Apple Watch Series 4+ (watchOS 10.0+)

### Installation

```bash
git clone git@github.com:tats-618/TennisServeAnalyzer.git
cd TennisServeAnalyzer
open TennisServeAnalyzer.xcodeproj
```

### Usage

1. Wear Apple Watch on dominant hand
2. Position iPhone vertically to capture full serve
3. Tap "Start Recording"
4. Execute your serve
5. Review your score and metrics

## 📊 Performance

- Camera FPS: 110-120 ✅
- Pose Detection: 13-15 fps ✅
- IMU Rate: 95-100Hz ✅
- Memory: ~150MB ✅

## 🗺️ Roadmap

- [x] Basic recording and analysis
- [x] Real-time pose detection
- [x] 7-metric scoring
- [ ] Ball tracking integration
- [ ] Data persistence
- [ ] Historical comparison

## 📄 License

Copyright © 2025 Tatsuki Shimamoto. All rights reserved.

## 👤 Author

**Tatsuki Shimamoto**
- GitHub: [@tats-618](https://github.com/tats-618)

---

**Made with ❤️ for tennis players**
