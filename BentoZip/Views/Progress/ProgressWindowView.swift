import SwiftUI
import BentoZipCore

struct ProgressWindowView: View {
    @Environment(ProgressState.self) private var progressState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: progressState.operationDescription.contains("压缩") ? "doc.zipper" : "arrow.down.doc.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(progressState.operationDescription)
                    .font(.body)
                    .lineLimit(1)
                
                ProgressView(value: progressState.operationProgress, total: 1.0)
                    .progressViewStyle(.linear)

                Text("\(Int(progressState.operationProgress * 100))%")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.leading, 16)
        .frame(width: 360)
        .background(.regularMaterial)
        .onChange(of: progressState.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss {
                closeWindow()
                progressState.shouldDismiss = false
            }
        }
    }

    private var progressDetailText: String {
        let percent = Int(progressState.operationProgress * 100)
        if progressState.operationProgress <= 0 {
            return "准备中..."
        } else if percent >= 100 {
            return "即将完成"
        } else {
            return "\(percent)% 已完成"
        }
    }

    private func closeWindow() {
        NSApplication.shared.keyWindow?.close()
    }
}

#Preview {
    ProgressWindowView()
        .environment(ProgressState())
}
