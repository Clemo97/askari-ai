import Foundation
import FoundationModels
import PowerSync

// MARK: - SQL cursor helper

private func row(_ cursor: any SqlCursor) -> [String: String?] {
    var d: [String: String?] = [:]
    for (name, _) in cursor.columnNames {
        d[name] = try? cursor.getStringOptional(name: name)
    }
    return d
}

// MARK: - Tools

struct QueryRecentIncidentsTool: Tool {
    let name = "query_recent_incidents"
    let description = "Query patrol incidents from the local database. Returns incident type, description, date, severity, and ranger name."

    @Generable
    struct Arguments {
        @Guide(description: "Number of days to look back. 1 = today, 7 = last week, 30 = last month.")
        var daysBack: Int

        @Guide(description: "Optional spot type keyword to filter by, e.g. snare, carcass, footprint, cartridge, camp. Pass an empty string to return all types.")
        var incidentType: String
    }

    func call(arguments: Arguments) async throws -> String {
        let db = SystemManager.shared.db
        var conditions = ["mf.created_at >= datetime('now', '-\(arguments.daysBack) days')"]
        var params: [String?] = []

        if !arguments.incidentType.isEmpty {
            let term: String? = "%\(arguments.incidentType.lowercased())%"
            conditions.append("(LOWER(st.code_name) LIKE ? OR LOWER(st.display_name) LIKE ?)")
            params.append(term)
            params.append(term)
        }

        let whereClause = "WHERE " + conditions.joined(separator: " AND ")
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

        let rows = try await db.getAll(sql: sql, parameters: params, mapper: row)
        guard !rows.isEmpty else {
            let label = arguments.incidentType.isEmpty ? "" : " for '\(arguments.incidentType)'"
            return "No incidents found in the last \(arguments.daysBack) day(s)\(label)."
        }

        let lines = rows.enumerated().map { i, r -> String in
            let type   = r["spot_type"]    as? String ?? "Unknown"
            let desc   = (r["description"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let ranger = r["ranger_name"]  as? String ?? "Unknown ranger"
            let date   = String((r["created_at"] as? String ?? "").prefix(10))
            let sev    = (r["severity"]    as? String ?? "").capitalized
            let detail = desc.isEmpty ? "" : ": \(desc)"
            return "\(i + 1). \(type)\(detail) — \(ranger), \(date), \(sev)"
        }

        return "Found \(rows.count) incident(s) in the last \(arguments.daysBack) day(s):\n"
             + lines.joined(separator: "\n")
    }
}

struct GetRangerStatsTool: Tool {
    let name = "get_ranger_stats"
    let description = "Ranger leaderboard ranked by number of incidents logged in a time period."

    @Generable
    struct Arguments {
        @Guide(description: "Days back to look for stats, e.g. 30")
        var daysBack: Int

        @Guide(description: "Max number of rangers to return, e.g. 5")
        var limit: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let db  = SystemManager.shared.db
        let lim = max(1, min(arguments.limit, 20))

        let rows = try await db.getAll(
            sql: """
                SELECT
                    s.first_name || ' ' || s.last_name AS ranger_name,
                    COUNT(mf.id) AS incident_count
                FROM map_features mf
                JOIN staff s ON s.id = mf.captured_by_staff_id
                WHERE mf.created_at >= datetime('now', '-\(arguments.daysBack) days')
                GROUP BY mf.captured_by_staff_id
                ORDER BY incident_count DESC
                LIMIT \(lim)
            """,
            parameters: [],
            mapper: row
        )

        guard !rows.isEmpty else {
            return "No incident data available for the last \(arguments.daysBack) days."
        }

        let lines = rows.enumerated().map { i, r -> String in
            let name  = r["ranger_name"]    as? String ?? "Unknown"
            let count = r["incident_count"] as? String ?? "0"
            return "\(i + 1). \(name) — \(count) incidents"
        }
        return "Top rangers (last \(arguments.daysBack) days):\n" + lines.joined(separator: "\n")
    }
}

struct LogIncidentTool: Tool {
    let name = "log_incident"
    let description = "Log a new poaching incident to the local database. It will sync to the server when connectivity returns."

    @Generable
    struct Arguments {
        @Guide(description: "Incident type code, e.g. snare, carcass, poacher_camp, spent_cartridge")
        var incidentType: String

        @Guide(description: "Ranger's description of what was found")
        var description: String

        @Guide(description: "Severity: low, medium, high, or critical")
        var severity: String

        @Guide(description: "Staff UUID of the ranger (optional — leave empty to omit)")
        var staffId: String
    }

    func call(arguments: Arguments) async throws -> String {
        let db = SystemManager.shared.db

        let spotRows = try await db.getAll(
            sql: "SELECT id FROM spot_types WHERE LOWER(code_name) = ? LIMIT 1",
            parameters: [arguments.incidentType.lowercased()],
            mapper: row
        )
        let spotTypeId = spotRows.first?["id"] as? String

        let parkRows = try await db.getAll(
            sql: "SELECT id FROM parks LIMIT 1",
            parameters: [],
            mapper: row
        )
        let parkId = parkRows.first?["id"] as? String ?? ""

        let incidentId = UUID().uuidString
        let now        = SystemManager.isoString(from: Date())
        let geometry   = #"{"type":"Point","coordinates":[0,0]}"#
        let staffId: String? = arguments.staffId.isEmpty ? nil : arguments.staffId

        try await db.execute(
            sql: """
                INSERT INTO map_features
                    (id, name, description, geometry, created_by, captured_by_staff_id,
                     created_at, updated_at, media_url, spot_type_id, park_id, is_resolved, severity)
                VALUES (?,?,?,?,?,?,?,?,'[]',?,?,0,?)
            """,
            parameters: [
                incidentId,
                arguments.incidentType.replacingOccurrences(of: "_", with: " ").capitalized,
                arguments.description,
                geometry,
                staffId, staffId,
                now, now,
                spotTypeId,
                parkId,
                arguments.severity,
            ] as [Sendable?]
        )

        return "Incident logged: \(arguments.incidentType) — \"\(arguments.description)\" [severity: \(arguments.severity)]. Will sync when online."
    }
}
