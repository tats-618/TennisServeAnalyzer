//
//  StatusIndicatorView.swift
//  TennisServeAnalyzer
//
//  Created by 島本健生 on 2025/05/28.
//

import SwiftUI

struct iOSStatusIndicatorView: View {
    let state: DataCollectionState
    
    var body: some View {
        HStack(spacing: 12) {
            // ステータスアイコン
            statusIcon
                .foregroundColor(statusColor)
                .font(.title)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(statusText)
                    .font(.headline)
                    .foregroundColor(statusColor)
                
                Text(statusDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(statusColor.opacity(0.1))
        )
    }
    
    private var statusIcon: Image {
        switch state {
        case .idle:
            return Image(systemName: "circle")
        case .collecting:
            return Image(systemName: "record.circle.fill")
        case .completed:
            return Image(systemName: "checkmark.circle.fill")
        case .error(_):
            return Image(systemName: "exclamationmark.triangle.fill")
        }
    }
    
    private var statusText: String {
        switch state {
        case .idle:
            return "準備完了"
        case .collecting:
            return "記録中..."
        case .completed:
            return "解析完了"
        case .error(let message):
            return "エラー"
        }
    }
    
    private var statusDescription: String {
        switch state {
        case .idle:
            return "Apple Watchで記録を開始してください"
        case .collecting:
            return "Apple Watchからセンサーデータを収集中"
        case .completed:
            return "データ解析が正常に完了しました"
        case .error(let message):
            return message
        }
    }
    
    private var statusColor: Color {
        switch state {
        case .idle:
            return .blue
        case .collecting:
            return .red
        case .completed:
            return .green
        case .error(_):
            return .orange
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        iOSStatusIndicatorView(state: .idle)
        iOSStatusIndicatorView(state: .collecting)
        iOSStatusIndicatorView(state: .completed)
        iOSStatusIndicatorView(state: .error("テストエラー"))
    }
    .padding()
}
