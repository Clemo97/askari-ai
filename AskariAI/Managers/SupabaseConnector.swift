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
                    var stringData = entry.opData ?? [:]
                    stringData["id"] = entry.id

                    // Convert JSON-like text values to AnyJSON objects so PostgREST
                    // stores them as proper JSONB objects, not JSONB strings.
                    var jsonData: [String: AnyJSON] = [:]
                    for (key, optVal) in stringData {
                        guard let val = optVal else {
                            jsonData[key] = .null
                            continue
                        }
                        let trimmed = val.trimmingCharacters(in: .whitespaces)
                        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) {
                            if let rawData = trimmed.data(using: .utf8),
                               let decoded = try? JSONDecoder().decode(AnyJSON.self, from: rawData) {
                                jsonData[key] = decoded
                                continue
                            }
                        }
                        jsonData[key] = .string(val)
                    }
                    try await client.from(table).upsert(jsonData).execute()

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

    /// Fetch the current user's staff profile directly from Supabase REST.
    /// Use this after sign-in/sign-up before PowerSync has had a chance to sync.
    func fetchCurrentStaff() async throws -> StaffMember? {
        guard let user = await currentUser else { return nil }

        // Explicit CodingKeys so we never rely on decoder key strategy.
        struct StaffRow: Decodable {
            let id: String
            let email: String
            let firstName: String
            let lastName: String
            let rank: String?
            let parkId: String?
            let userId: String?
            let avatarUrl: String?
            let createdAt: String?
            let isActive: Bool?

            enum CodingKeys: String, CodingKey {
                case id, email, rank
                case firstName  = "first_name"
                case lastName   = "last_name"
                case parkId     = "park_id"
                case userId     = "user_id"
                case avatarUrl  = "avatar_url"
                case createdAt  = "created_at"
                case isActive   = "is_active"
            }
        }

        let rows: [StaffRow] = try await client.from("staff")
            .select()
            .eq("user_id", value: user.id.uuidString)
            .limit(1)
            .execute()
            .value

        guard let row = rows.first, let id = UUID(uuidString: row.id) else { return nil }

        let createdAt = row.createdAt.flatMap(SystemManager.parseDate) ?? Date()

        return StaffMember(
            id: id,
            email: row.email,
            firstName: row.firstName,
            lastName: row.lastName,
            rank: StaffMember.Rank(rawValue: row.rank ?? "ranger") ?? .ranger,
            parkId: row.parkId.flatMap(UUID.init),
            userId: row.userId.flatMap(UUID.init),
            avatarURL: row.avatarUrl,
            createdAt: createdAt,
            isActive: row.isActive ?? true
        )
    }

    func signUp(email: String, password: String, firstName: String, lastName: String, rank: String = "ranger") async throws {
        // Pass name and rank as user metadata — a SECURITY DEFINER trigger on auth.users
        // will create the staff row with the correct rank, bypassing RLS.
        try await client.auth.signUp(
            email: email,
            password: password,
            data: [
                "first_name": .string(firstName),
                "last_name": .string(lastName),
                "rank": .string(rank)
            ]
        )
    }
}
