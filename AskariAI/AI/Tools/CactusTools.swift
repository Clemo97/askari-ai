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
// Queries map_features by block name, incident type, and date range.

struct QueryRecentIncidentsTool: CactusFunction {
    @JSONSchema
    struct Input: Codable, Sendable {
        @JSONSchemaProperty(description: "Park block name to search in. Use 'all' for all blocks.")
        let blockName: String

        @JSONSchemaProperty(description: "Number of days back to look (e.g. 7, 14, 30).")
        let daysBack: Int

        @JSONSchemaProperty(description: "Incident type filter, e.g. 'snare', 'carcass'. Leave empty for all types.")
        let incidentType: String
    }

    let name = "query_recent_incidents"
    let description = "Get recent poaching incidents from a specific park block or all blocks. Returns incident names, descriptions, dates, and ranger who logged them."

    func invoke(input: Input) async throws -> sending String {
        let db = SystemManager.shared.db
        var conditions = ["mf.created_at >= datetime('now', '-\(input.daysBack) days')"]
        var params: [String?] = []

        if input.blockName.lowercased() != "all" && !input.blockName.isEmpty {
            // Join through park_blocks by checking if incident is in block geometry (simplified: use block name in notes)
            conditions.append("pb.block_name LIKE ?")
            params.append("%\(input.blockName)%")
        }

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
            return "No incidents found in \(input.blockName == "all" ? "any block" : input.blockName) over the last \(input.daysBack) days\(input.incidentType.isEmpty ? "" : " for type: \(input.incidentType)")."
        }

        return rows.map { row -> String in
            let type = row["spot_type"] as? String ?? row["name"] as? String ?? "Unknown"
            let desc = row["description"] as? String ?? ""
            let ranger = row["ranger_name"] as? String ?? "Unknown ranger"
            let date = row["created_at"] as? String ?? ""
            let severity = row["severity"] as? String ?? ""
            return "[\(type)] \(desc) — by \(ranger) on \(date) [\(severity)]"
        }.joined(separator: "\n")
    }
}

// MARK: - GetBlockPatrolStatusTool

struct GetBlockPatrolStatusTool: CactusFunction {
    @JSONSchema
    struct Input: Codable, Sendable {
        @JSONSchemaProperty(description: "Block name to get status for. Use 'all' for all blocks.")
        let blockName: String
    }

    let name = "get_block_patrol_status"
    let description = "Get the current patrol status of park blocks, including last patrol date, health score, and whether they are overdue."

    func invoke(input: Input) async throws -> sending String {
        let db = SystemManager.shared.db

        let filter = input.blockName.lowercased() == "all" ? "" : "WHERE block_name LIKE ?"
        let params: [String?] = input.blockName.lowercased() == "all" ? [] : ["%\(input.blockName)%"]

        let sql = """
            SELECT
                block_name,
                last_patrolled,
                threshold,
                rate_of_decay,
                CAST(
                    MAX(0, 1.0 - (julianday('now') - julianday(COALESCE(last_patrolled, '2000-01-01'))) / rate_of_decay)
                    * 100 AS INTEGER
                ) AS health_pct,
                CASE
                    WHEN last_patrolled IS NULL THEN 'Never patrolled'
                    WHEN (julianday('now') - julianday(last_patrolled)) > rate_of_decay THEN 'OVERDUE'
                    ELSE 'OK'
                END AS patrol_status
            FROM park_blocks
            \(filter)
            ORDER BY health_pct ASC
        """

        let rows = try await db.getAll(sql: sql, parameters: params, mapper: cursorToDict)

        if rows.isEmpty { return "No blocks found matching '\(input.blockName)'." }

        return rows.map { row -> String in
            let name = row["block_name"] as? String ?? "Unknown"
            let status = row["patrol_status"] as? String ?? "Unknown"
            let health = row["health_pct"] as? String ?? "?"
            let last = row["last_patrolled"] as? String ?? "never"
            return "\(name): \(status) — health \(health)%, last patrolled: \(last)"
        }.joined(separator: "\n")
    }
}

// MARK: - GetMissionSummaryTool

struct GetMissionSummaryTool: CactusFunction {
    @JSONSchema
    struct Input: Codable, Sendable {
        @JSONSchemaProperty(description: "Mission UUID to summarize.")
        let missionId: String
    }

    let name = "get_mission_summary"
    let description = "Get a summary of a mission including objectives, assigned rangers, scores, and incident count."

    func invoke(input: Input) async throws -> sending String {
        let db = SystemManager.shared.db

        let missionRows = try await db.getAll(
            sql: "SELECT * FROM missions WHERE id = ? LIMIT 1",
            parameters: [input.missionId],
            mapper: cursorToDict
        )
        guard let m = missionRows.first else { return "Mission not found." }

        let incidentCount = try await db.getAll(
            sql: "SELECT COUNT(*) as count FROM map_features WHERE mission_id = ?",
            parameters: [input.missionId],
            mapper: cursorToDict
        ).first?["count"] as? String ?? "0"

        let scoreRows = try await db.getAll(
            sql: "SELECT * FROM mission_scores WHERE mission_id = ? LIMIT 1",
            parameters: [input.missionId],
            mapper: cursorToDict
        )
        let score = scoreRows.first

        var summary = """
        Mission: \(m["name"] as? String ?? "Unknown")
        Objectives: \(m["objectives"] as? String ?? "None")
        Type: \(m["patrol_type"] as? String ?? "Unknown")
        Status: \(m["mission_state"] as? String ?? "Unknown")
        Incidents logged: \(incidentCount)
        """

        if let dist = score?["distance_traveled_km"] as? String {
            summary += "\nDistance traveled: \(dist) km"
        }

        return summary
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

        @JSONSchemaProperty(description: "Mission UUID this incident belongs to.")
        let missionId: String

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

        // Resolve park_id from mission
        let missions = try await db.getAll(
            sql: "SELECT park_id, leader_id FROM missions WHERE id = ? LIMIT 1",
            parameters: [input.missionId],
            mapper: cursorToDict
        )
        let parkId = missions.first?["park_id"] as? String ?? ""
        let leaderId = missions.first?["leader_id"] as? String ?? ""

        let staffId = input.staffId.isEmpty ? leaderId : input.staffId
        let incidentId = UUID().uuidString
        let now = SystemManager.isoString(from: Date())

        // Geometry placeholder — in production, use the ranger's current GPS location
        let geometry = #"{"type":"Point","coordinates":[0,0]}"#

        try await db.execute(
            sql: """
            INSERT INTO map_features
                (id, name, description, geometry, created_by, captured_by_staff_id,
                 created_at, media_url, mission_id, spot_type_id, park_id,
                 is_resolved, severity)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            """,
            parameters: [
                incidentId,
                input.incidentType.replacingOccurrences(of: "_", with: " ").capitalized,
                input.description,
                geometry,
                staffId, staffId,
                now,
                "[]",
                input.missionId,
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
