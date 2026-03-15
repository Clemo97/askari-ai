import Foundation
import Supabase
import PowerSync

// MARK: - Supabase Connector

/// Bridges PowerSync ↔ Supabase Auth + Database.
/// Provides JWT credentials to PowerSync and uploads local mutations to Supabase.
@Observable
final class SupabaseConnector: PowerSyncBackendConnectorProtocol, @unchecked Sendable {

    let client: SupabaseClient

    init() {
        client = SupabaseClient(
            supabaseURL: Secrets.supabaseURL,
            supabaseKey: Secrets.supabaseAnonKey
        )
    }

    // MARK: Current user

    var currentUser: User? {
        get async {
            try? await client.auth.user()
        }
    }

    // MARK: PowerSyncBackendConnectorProtocol

    func fetchCredentials() async throws -> PowerSyncCredentials? {
        let session = try await client.auth.session
        return PowerSyncCredentials(
            endpoint: Secrets.powerSyncEndpoint,
            token: session.accessToken
        )
    }

    func uploadData(database: PowerSyncDatabaseProtocol) async throws {
        guard let transaction = try await database.getNextCrudTransaction() else { return }

        do {
            for entry in transaction.crud {
                let table = entry.table

                switch entry.op {
                case .put:
                    var data = entry.opData ?? [:]
                    data["id"] = entry.id
                    try await client.from(table).upsert(data).execute()

                case .patch:
                    guard let opData = entry.opData else { continue }
                    try await client.from(table).update(opData).eq("id", value: entry.id).execute()

                case .delete:
                    try await client.from(table).delete().eq("id", value: entry.id).execute()
                }
            }
            try await transaction.complete()
        } catch {
            // Fatal Postgres errors — discard so they don't block the queue
            let fatalCodes = ["22", "23", "42501", "PGRST204"]
            let msg = error.localizedDescription
            if fatalCodes.contains(where: { msg.contains($0) }) {
                try await transaction.complete()
            } else {
                throw error
            }
        }
    }

    // MARK: Auth helpers

    func signIn(email: String, password: String) async throws {
        try await client.auth.signIn(email: email, password: password)
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }
}
