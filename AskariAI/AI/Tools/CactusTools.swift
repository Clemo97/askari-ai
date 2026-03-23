import Foundation
import Cactus
import PowerSync

// MARK: - Cursor helper

/// Converts a SqlCursor row into a convenience dictionary of column → String?.
private func cursorToDict(_ cursor: any SqlCursor) -> [String: String?] {
    var dict: [String: String?] = [:]
    for (name, _) in cursor.columnNames {
        dict[name] = (try? cursor.getStringOptional(name: name)) ?? nil
    }
    return dict
}

// MARK: - QueryRecentIncidentsTool
// Queries map_features by incident type and date range.

struct QueryRecentIncidentsTool: CactusFunction {
    @JSONSchema
    struct Input: Codable, Sendable {
        @JSONSchemaProperty(description: "Number of days back to look (e.g. 7, 14, 30).")
        let daysBack: Int

        @JSONSchemaProperty(description: "Incident type filter, e.g. 'snare', 'carcass'. Leave empty for all types.")
        let incidentType: String
    }

    let name = "query_recent_incidents"
    let description = "Get recent poaching incidents. Returns incident names, descriptions, dates, severity, and ranger who logged them."

    func invoke(input: Input) async throws -> sending String {
        let db = SystemManager.shared.db
        var conditions = ["mf.created_at >= datetime('now', '-\(input.daysBack) days')"]
        var params: [String?] = []

        if !input.incidentType.isEmpty {
            conditions.append("st.code_name LIKE ?")
            params.append("%\(input.incidentType.lowercased())%")
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let sql = """
            SELECT
                mf.name,
                mf.description,
                mf.created_at,
                mf.severity,
                s.first_name || ' ' || s.last_name AS ranger_name,
                st.display_name AS spot_type
            FROM map_features mf
            LEFT JOIN staff s ON s.id = mf.captured_by_staff_id
            LEFT JOIN spot_types st ON st.id = mf.spot_type_id
            \(whereClause)
            ORDER BY mf.created_at DESC
            LIMIT 20
        """

        let rows = try await db.getAll(sql: sql, parameters: params, mapper: cursorToDict)

        if rows.isEmpty {
            let typeLabel = input.incidentType.isEmpty ? "" : " for \(input.incidentType)"
            return "No incidents found in the last \(input.daysBack) day(s)\(typeLabel)."
        }

        let formatted = rows.enumerated().map { i, row -> String in
            let type = row["spot_type"] as? String ?? "Unknown type"
            let desc = (row["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ranger = row["ranger_name"] as? String ?? "Unknown ranger"
            let rawDate = row["created_at"] as? String ?? ""
            let severity = (row["severity"] as? String ?? "").capitalized
            let dateLabel = Self.formatDate(rawDate)
            let descPart = desc.isEmpty ? "" : " — \(desc)"
            return "\(i + 1). \(type)\(descPart)\n   By \(ranger) · \(dateLabel) · \(severity)"
        }.joined(separator: "\n")

        let header = "Found \(rows.count) incident(s) in the last \(input.daysBack) day(s):"
        return "\(header)\n\(formatted)"
    }

    private static func formatDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) {
            let out = DateFormatter()
            out.dateStyle = .medium
            out.timeStyle = .short
            return out.string(from: date)
        }
        // Fallback: trim to just date portion
        return String(iso.prefix(10))
    }
}

// MARK: - LogIncidentTool

struct LogIncidentTool: CactusFunction {
    @JSONSchema
    struct Input: Codable, Sendable {
        @JSONSchemaProperty(description: "Type of incident, e.g. 'snare', 'carcass', 'poacher_camp'.")
        let incidentType: String

        @JSONSchemaProperty(description: "Ranger's description of what they found.")
        let description: String

        @JSONSchemaProperty(description: "Severity: 'low', 'medium', 'high', or 'critical'.")
        let severity: String

        @JSONSchemaProperty(description: "Optional: ranger staff UUID who found this. Leave empty to use current user.")
        let staffId: String
    }

    let name = "log_incident"
    let description = "Log a new poaching incident into the local database. This will sync to the backend when connectivity is available."

    func invoke(input: Input) async throws -> sending String {
        let db = SystemManager.shared.db

        // Resolve spot type ID from code name
        let spotTypes = try await db.getAll(
            sql: "SELECT id FROM spot_types WHERE code_name = ? LIMIT 1",
            parameters: [input.incidentType.lowercased()],
            mapper: cursorToDict
        )
        let spotTypeId = spotTypes.first?["id"] as? String

        // Resolve park_id from local parks table
        let parks = try await db.getAll(
            sql: "SELECT id FROM parks LIMIT 1",
            parameters: [],
            mapper: cursorToDict
        )
        let parkId = parks.first?["id"] as? String ?? ""

        let staffId = input.staffId.isEmpty ? "" : input.staffId
        let incidentId = UUID().uuidString
        let now = SystemManager.isoString(from: Date())

        // Geometry placeholder — in production, use the ranger's current GPS location
        let geometry = #"{"type":"Point","coordinates":[0,0]}"#

        try await db.execute(
            sql: """
            INSERT INTO map_features
                (id, name, description, geometry, created_by, captured_by_staff_id,
                 created_at, updated_at, media_url, spot_type_id, park_id,
                 is_resolved, severity)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            """,
            parameters: [
                incidentId,
                input.incidentType.replacingOccurrences(of: "_", with: " ").capitalized,
                input.description,
                geometry,
                staffId, staffId,
                now, now,
                "[]",
                spotTypeId,
                parkId,
                input.severity,
            ] as [Sendable?]
        )

        return "✅ Incident logged: \(input.incidentType) — \"\(input.description)\" [severity: \(input.severity)]. It will sync when connectivity is available."
    }
}

// MARK: - GetRangerStatsTool

struct GetRangerStatsTool: CactusFunction {
    @JSONSchema
    struct Input: Codable, Sendable {
        @JSONSchemaProperty(description: "Number of days back to look for stats (e.g. 30).")
        let daysBack: Int

        @JSONSchemaProperty(description: "Limit the number of rangers returned (e.g. 5 for top 5).")
        let limit: Int
    }

    let name = "get_ranger_stats"
    let description = "Get a leaderboard of rangers ranked by number of incidents logged in a time period."

    func invoke(input: Input) async throws -> sending String {
        let db = SystemManager.shared.db
        let lim = max(1, min(input.limit, 20))

        let rows = try await db.getAll(
            sql: """
                SELECT
                    s.first_name || ' ' || s.last_name AS ranger_name,
                    COUNT(mf.id) AS incident_count
                FROM map_features mf
                JOIN staff s ON s.id = mf.captured_by_staff_id
                WHERE mf.created_at >= datetime('now', '-\(input.daysBack) days')
                GROUP BY mf.captured_by_staff_id
                ORDER BY incident_count DESC
                LIMIT \(lim)
            """,
            parameters: [],
            mapper: cursorToDict
        )

        if rows.isEmpty { return "No incident data available for the last \(input.daysBack) days." }

        let lines = rows.enumerated().map { i, row -> String in
            let name = row["ranger_name"] as? String ?? "Unknown"
            let count = row["incident_count"] as? String ?? "0"
            return "\(i + 1). \(name) — \(count) incidents"
        }
        return "Top rangers (last \(input.daysBack) days):\n" + lines.joined(separator: "\n")
    }
}
