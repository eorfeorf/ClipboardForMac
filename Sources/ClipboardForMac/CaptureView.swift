import SwiftUI

enum CaptureKind: String, CaseIterable {
    case image = "画像"
    case video = "動画"
}

enum CaptureMode: String, CaseIterable {
    case region = "範囲"
    case window = "ウィンドウ"
    case display = "画面全体"

    var symbol: String {
        switch self {
        case .region: "crop"
        case .window: "macwindow"
        case .display: "display"
        }
    }
}

struct CaptureView: View {
    let capture: (CaptureKind, CaptureMode) -> Void
    let cancel: () -> Void

    @State private var kind: CaptureKind = .image
    @State private var mode: CaptureMode = .region

    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 6) {
                ForEach(CaptureKind.allCases, id: \.self) { option in
                    Button {
                        kind = option
                    } label: {
                        Label(option.rawValue, systemImage: option == .image ? "camera" : "video")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 6)
                    .background(kind == option ? Color.accentColor.opacity(0.16) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityAddTraits(kind == option ? .isSelected : [])
                }
            }
            HStack(spacing: 5) {
                ForEach(CaptureMode.allCases, id: \.self) { option in
                    Button {
                        mode = option
                    } label: {
                        Label(option.rawValue, systemImage: option.symbol)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 6)
                    .background(mode == option ? Color.accentColor.opacity(0.16) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityAddTraits(mode == option ? .isSelected : [])
                }
            }
            HStack {
                Spacer()
                Button("キャンセル", action: cancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("撮影") { capture(kind, mode) }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(width: 354, height: 142)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}
