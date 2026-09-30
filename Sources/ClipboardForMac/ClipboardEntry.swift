import Foundation

enum ClipboardKind: String, Codable {
    case text
    case image
    case files
}

struct ClipboardEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: ClipboardKind
    let fingerprint: String
    var createdAt: Date
    var isPinned: Bool
    var text: String?
    var imageFilename: String?
    var fileURLs: [String]?
    var richTextFilename: String? = nil

    var title: String {
        switch kind {
        case .text:
            let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? "空白" : value
        case .image:
            return "画像"
        case .files:
            let names = (fileURLs ?? []).compactMap { URL(string: $0)?.lastPathComponent }
            guard let first = names.first else { return "ファイル" }
            return names.count == 1 ? first : "\(first) ほか\(names.count - 1)件"
        }
    }
}
