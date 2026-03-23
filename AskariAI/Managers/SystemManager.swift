import Foundation
import PowerSync
import Supabase

// MARK: - SupabaseStorageAdapter

/// PowerSync RemoteStorageAdapter backed by Supabase Storage.
final class SupabaseRemoteStorageAdapter: RemoteStorageAdapter {
    private let client: SupabaseClient
    private let bucket: String

    init(client: SupabaseClient, bucket: String) {
        self.client = client
        self.bucket = bucket
    }

    func uploadFile(fileData: Data, attachment: Attachment) async throws {
        _ = try await client.storage.from(bucket).upload(
            attachment.filename,
            data: fileData,
            options: FileOptions(contentType: attachment.mediaType ?? "application/octet-stream")
        )
    }

    func downloadFile(attachment: Attachment) async throws -> Data {
        return try await client.storage.from(bucket).download(path: attachment.filename)
    }

    func deleteFile(attachment: Attachment) async throws {
        _ = try await client.storage.from(bucket).remove(paths: [attachment.filename])
    }
}

// MARK: - SystemManager

/// Central coordinator for PowerSync database and Supabase connector.
/// @MainActor — all DB calls must be awaited in async contexts.
@Observable
final class SystemManager: @unchecked Sendable {

    let connector = SupabaseConnector()
    let db: PowerSyncDatabaseProtocol
    var attachments: AttachmentQueue?

    private(set) var isSyncConnected = false

    /// Active sync-stream subscription for the consolidated `migrated_to_streams` stream.
    /// auto_subscribe: true on the server already begins syncing on connect; we subscribe
    /// explicitly here only to call waitForFirstSync() before returning from connect().
    private var syncSubscriptions: [any SyncStreamSubscription] = []

    /// Shared instance used by AI tools and other non-TCA code.
    /// The TCA `@Dependency(\.systemManager)` holds the same instance.
    static let shared = SystemManager()

    init() {
        db = PowerSyncDatabase(
            schema: AppSchema,
            dbFilename: "askari-powersync.sqlite"
        )
    }

    // MARK: Connect

    func connect() async throws {
        // Guard: don't attempt to connect if there is no active auth session.
        // fetchCredentials() would throw "Auth session missing" and
        // waitForFirstSync() would block indefinitely.
        guard (try? await connector.client.auth.session) != nil else { return }

        try await db.connect(connector: connector)

        // Subscribe to the single consolidated stream. The server resolves CTE parameters
        // via auth.user_id() — ranger and admin data are filtered server-side automatically.
        // auto_subscribe: true means sync begins immediately on connect; we subscribe
        // explicitly only to get a handle for waitForFirstSync().
        let sub = try await db.syncStream(name: "migrated_to_streams", params: nil).subscribe()
        syncSubscriptions = [sub]

        // Block until initial sync completes so the map has park data before rendering.
        try await sub.waitForFirstSync()

        // Set up attachment sync for incident media
        if let bucket = Secrets.supabaseStorageBucket {
            let attachmentsDir = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("attachments")
                .path

            let localDb = db
            attachments = AttachmentQueue(
                db: db,
                remoteStorage: SupabaseRemoteStorageAdapter(
                    client: connector.client,
                    bucket: bucket
                ),
                attachmentsDirectory: attachmentsDir,
                watchAttachments: {
                    // Expand JSON arrays stored in media_url (e.g. ["uuid1","uuid2"])
                    // into one WatchedAttachmentItem per attachment ID.
                    try localDb.watch(
                        sql: """
                            SELECT je.value AS attachment_id
                            FROM map_features, json_each(
                                CASE
                                    WHEN media_url LIKE '[%' THEN media_url
                                    ELSE '[]'
                                END
                            ) AS je
                            WHERE media_url IS NOT NULL
                              AND media_url != '[]'
                              AND je.value NOT LIKE 'http%'
                        """,
                        parameters: []
                    ) { cursor in
                        let id = (try? cursor.getString(name: "attachment_id")) ?? UUID().uuidString
                        return WatchedAttachmentItem(id: id, filename: id)
                    }
                }
            )
            try await attachments?.startSync()
        }

        isSyncConnected = true
    }

    func disconnect() async throws {
        // Unsubscribe from all streams before disconnecting so the server
        // stops sending data and the TTL-based cache timers start cleanly.
        for sub in syncSubscriptions {
            try? await sub.unsubscribe()
        }
        syncSubscriptions = []
        try await db.disconnect()
        isSyncConnected = false
    }

    // MARK: Convenience queries

    func getCurrentUser() async throws -> StaffMember? {
        guard let user = await connector.currentUser else { return nil }
        let rows = try await db.getAll(
            sql: "SELECT * FROM staff WHERE user_id = ? LIMIT 1",
            parameters: [user.id.uuidString],
            mapper: { cursor in StaffMember(cursor: cursor) }
        )
        return rows.first.flatMap { $0 }
    }

    // MARK: Date helpers

    static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatters: [ISO8601DateFormatter] = [
            { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }(),
            { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }(),
            { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f }(),
        ]
        return formatters.compactMap { $0.date(from: string) }.first
    }

    static func isoString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - TCA Dependency

import ComposableArchitecture

private enum SystemManagerKey: DependencyKey {
    static let liveValue = SystemManager.shared
    static var testValue: SystemManager { SystemManager() }
}

extension DependencyValues {
    var systemManager: SystemManager {
        get { self[SystemManagerKey.self] }
        set { self[SystemManagerKey.self] = newValue }
    }
}
