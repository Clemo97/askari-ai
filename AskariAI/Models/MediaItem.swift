import Foundation

// MARK: - MediaItem

/// Represents a single captured photo or video before it is persisted.
enum MediaItem: Equatable {
    case image(data: Data)
    case video(data: Data, url: URL?)

    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }

    var data: Data {
        switch self {
        case .image(let d): return d
        case .video(let d, _): return d
        }
    }

    var mimeType: String { isVideo ? "video/mp4" : "image/jpeg" }
    var fileExtension: String { isVideo ? "mp4" : "jpg" }

    // Compare by byte count — avoids O(n) byte comparison for large media in TCA state.
    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        switch (lhs, rhs) {
        case (.image(let l), .image(let r)):
            return l.count == r.count
        case (.video(let l, let lu), .video(let r, let ru)):
            return l.count == r.count && lu == ru
        default:
            return false
        }
    }
}
