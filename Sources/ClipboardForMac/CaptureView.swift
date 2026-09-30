import AppKit
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

enum CaptureGeometry {
    static func screenshotRectangle(screen: NSScreen, region: CGRect) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayBounds = CGDisplayBounds(number.uint32Value)
        return [displayBounds.minX + region.minX,
                displayBounds.minY + screen.frame.height - region.maxY,
                region.width, region.height]
            .map { String(Int($0.rounded())) }
            .joined(separator: ",")
    }
}

struct CaptureView: View {
    let select: (CaptureKind, CaptureMode) -> Void
    let cancel: () -> Void

    @State private var kind: CaptureKind = .image
    @State private var mode: CaptureMode = .region

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(CaptureKind.allCases, id: \.self) { option in
                    Button {
                        kind = option
                        select(kind, mode)
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
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("キャンセル")
            }
            HStack(spacing: 5) {
                ForEach(CaptureMode.allCases, id: \.self) { option in
                    Button {
                        mode = option
                        select(kind, mode)
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
        }
        .padding(10)
        .frame(width: 354, height: 100)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}
