import SwiftUI
import UIKit
import Photos

// MARK: - IncidentDetailSheet

struct IncidentDetailSheet: View {
    let incident: Incident
    let spotTypes: [SpotType]

    var body: some View {
        NavigationStack {
            List {
                // Header: severity + timestamp
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        SeverityBadge(severity: incident.severity)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(incident.name)
                                .font(.title3.bold())
                            Text(incident.createdAt.formatted(.dateTime.month(.wide).day().year().hour().minute()))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if incident.isResolved {
                            Label("Resolved", systemImage: "checkmark.seal.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Spot type
                if let spotType = spotTypes.first(where: { $0.id == incident.spotTypeId }) {
                    Section("Category") {
                        Label(spotType.displayName, systemImage: "tag.fill")
                            .foregroundStyle(spotType.color)
                    }
                }

                // GPS
                Section("Location") {
                    Label(
                        String(format: "%.5f, %.5f",
                               incident.coordinate.latitude,
                               incident.coordinate.longitude),
                        systemImage: "mappin.circle.fill"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                // Description
                if !incident.description.isEmpty {
                    Section("Notes") {
                        Text(incident.description)
                            .font(.body)
                    }
                }

                // Media gallery
                if !incident.mediaAttachmentIds.isEmpty {
                    Section("Evidence (\(incident.mediaAttachmentIds.count))") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(incident.mediaAttachmentIds.enumerated()), id: \.offset) { index, attachmentId in
                                    let photoKitId = incident.localMediaIdentifiers.indices.contains(index)
                                        ? incident.localMediaIdentifiers[index]
                                        : nil
                                    AttachmentThumbnail(
                                        attachmentId: attachmentId,
                                        photoKitId: photoKitId?.isEmpty == false ? photoKitId : nil
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Incident Report")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - SeverityBadge

private struct SeverityBadge: View {
    let severity: Incident.Severity

    var body: some View {
        Text(severity.rawValue.uppercased())
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch severity {
        case .critical: return .purple
        case .high:     return .red
        case .medium:   return .orange
        case .low:      return .yellow
        }
    }
}

// MARK: - AttachmentThumbnail

/// Resolves an attachment ID → local sandbox file path → UIImage.
/// Falls back to PhotoKit if the sandbox file is not present.
private struct AttachmentThumbnail: View {
    let attachmentId: String
    let photoKitId: String?

    @State private var image: UIImage? = nil
    @State private var isVideo = false
    @State private var isLoading = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemFill))
                .frame(width: 100, height: 100)

            if isLoading {
                ProgressView()
            } else if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if isVideo {
                Image(systemName: "video.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 100, height: 100)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await resolve() }
    }

    private func resolve() async {
        defer { isLoading = false }

        // 1. Try PowerSync sandbox file
        let db = SystemManager.shared.db
        let rows = try? await db.getAll(
            sql: "SELECT local_uri, filename FROM attachments WHERE id = ? LIMIT 1",
            parameters: [attachmentId],
            mapper: { cursor -> (String?, String?) in
                (try? cursor.getStringOptional(name: "local_uri") ?? nil,
                 try? cursor.getStringOptional(name: "filename") ?? nil)
            }
        )
        if let (localUri, filename) = rows?.first,
           let localUri, !localUri.isEmpty {
            // Check if it's a photokit:// URI
            if localUri.hasPrefix("photokit://") {
                let pkId = String(localUri.dropFirst("photokit://".count))
                image = await fetchFromPhotoKit(localIdentifier: pkId)
                return
            }
            // Try sandbox file path
            if FileManager.default.fileExists(atPath: localUri) {
                let ext = (filename as NSString?)?.pathExtension.lowercased() ?? ""
                isVideo = ext == "mp4" || ext == "mov"
                if !isVideo {
                    image = UIImage(contentsOfFile: localUri)
                }
                return
            }
        }

        // 2. Fallback: PhotoKit
        if let pkId = photoKitId {
            image = await fetchFromPhotoKit(localIdentifier: pkId)
        }
    }

    @MainActor
    private func fetchFromPhotoKit(localIdentifier: String) async -> UIImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject, asset.mediaType == .image else { return nil }
        return await withCheckedContinuation { continuation in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat
            opts.isNetworkAccessAllowed = false
            opts.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 200, height: 200),
                contentMode: .aspectFill,
                options: opts
            ) { img, _ in
                continuation.resume(returning: img)
            }
        }
    }
}
