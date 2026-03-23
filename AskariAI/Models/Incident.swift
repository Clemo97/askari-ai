import Foundation
import CoreLocation
import PowerSync

// MARK: - Incident (map_features)

struct Incident: Identifiable, Codable {
    let id: UUID
    var name: String                // spot type display name
    var description: String         // ranger free-text notes
    var coordinate: CLLocationCoordinate2D
    var spotTypeId: UUID?
    var missionId: UUID?
    var capturedByStaffId: UUID?
    var createdBy: UUID
    var createdAt: Date
    var mediaAttachmentIds: [String]   // attachment IDs from AttachmentQueue
    var localMediaIdentifiers: [String] // matching PhotoKit localIdentifiers (positional)
    var parkId: UUID
    var isResolved: Bool
    var resolvedAt: Date?
    var resolvedBy: UUID?
    var severity: Severity

    enum Severity: String, Codable, CaseIterable {
        case low, medium, high, critical
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, latitude, longitude
        case spotTypeId, missionId, capturedByStaffId, createdBy, createdAt
        case mediaAttachmentIds, localMediaIdentifiers, parkId, isResolved, resolvedAt, resolvedBy, severity
    }

    init(
        id: UUID = UUID(),
        name: String,
        description: String,
        coordinate: CLLocationCoordinate2D,
        spotTypeId: UUID? = nil,
        missionId: UUID? = nil,
        capturedByStaffId: UUID? = nil,
        createdBy: UUID,
        createdAt: Date = Date(),
        mediaAttachmentIds: [String] = [],
        localMediaIdentifiers: [String] = [],
        parkId: UUID,
        isResolved: Bool = false,
        resolvedAt: Date? = nil,
        resolvedBy: UUID? = nil,
        severity: Severity = .medium
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.coordinate = coordinate
        self.spotTypeId = spotTypeId
        self.missionId = missionId
        self.capturedByStaffId = capturedByStaffId
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.mediaAttachmentIds = mediaAttachmentIds
        self.localMediaIdentifiers = localMediaIdentifiers
        self.parkId = parkId
        self.isResolved = isResolved
        self.resolvedAt = resolvedAt
        self.resolvedBy = resolvedBy
        self.severity = severity
    }

    // Codable bridging for CLLocationCoordinate2D
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        let lat = try c.decode(Double.self, forKey: .latitude)
        let lon = try c.decode(Double.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        spotTypeId = try c.decodeIfPresent(UUID.self, forKey: .spotTypeId)
        missionId = try c.decodeIfPresent(UUID.self, forKey: .missionId)
        capturedByStaffId = try c.decodeIfPresent(UUID.self, forKey: .capturedByStaffId)
        localMediaIdentifiers = (try? c.decode([String].self, forKey: .localMediaIdentifiers)) ?? []
        createdBy = try c.decode(UUID.self, forKey: .createdBy)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        mediaAttachmentIds = try c.decode([String].self, forKey: .mediaAttachmentIds)
        parkId = try c.decode(UUID.self, forKey: .parkId)
        isResolved = try c.decode(Bool.self, forKey: .isResolved)
        resolvedAt = try c.decodeIfPresent(Date.self, forKey: .resolvedAt)
        resolvedBy = try c.decodeIfPresent(UUID.self, forKey: .resolvedBy)
        severity = try c.decode(Severity.self, forKey: .severity)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(coordinate.latitude, forKey: .latitude)
        try c.encode(coordinate.longitude, forKey: .longitude)
        try c.encodeIfPresent(spotTypeId, forKey: .spotTypeId)
        try c.encodeIfPresent(missionId, forKey: .missionId)
        try c.encodeIfPresent(capturedByStaffId, forKey: .capturedByStaffId)
        try c.encode(createdBy, forKey: .createdBy)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(mediaAttachmentIds, forKey: .mediaAttachmentIds)
        try c.encode(parkId, forKey: .parkId)
        try c.encode(isResolved, forKey: .isResolved)
        try c.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
        try c.encodeIfPresent(resolvedBy, forKey: .resolvedBy)
        try c.encode(severity, forKey: .severity)
    }
}

// MARK: - PowerSync cursor → Incident

extension Incident {
    init?(cursor: any SqlCursor) {
        guard
            let idStr = try? cursor.getString(name: "id"), let id = UUID(uuidString: idStr),
            let name = try? cursor.getString(name: "name"),
            let createdByStr = try? cursor.getString(name: "created_by"), let createdBy = UUID(uuidString: createdByStr),
            let createdAtStr = try? cursor.getString(name: "created_at"), let createdAt = SystemManager.parseDate(createdAtStr),
            let parkStr = try? cursor.getString(name: "park_id"), let parkId = UUID(uuidString: parkStr)
        else { return nil }

        let geometryRaw = ((try? cursor.getStringOptional(name: "geometry")) ?? nil) ?? "{}"
        // Handle double-encoded JSONB: if stored as a JSONB string it comes back with surrounding
        // quotes (e.g. `"{\"type\":\"Point\",…}"`) — unwrap it first.
        let geometryUnwrapped: String
        let trimmedRaw = geometryRaw.trimmingCharacters(in: .whitespaces)
        if trimmedRaw.hasPrefix("\""),
           let inner = try? JSONDecoder().decode(String.self, from: Data(trimmedRaw.utf8)) {
            geometryUnwrapped = inner.trimmingCharacters(in: .whitespaces)
        } else {
            geometryUnwrapped = trimmedRaw
        }
        var lat = 0.0, lon = 0.0
        if let data = geometryUnwrapped.data(using: .utf8),
           let geo = try? JSONDecoder().decode(GeoJSONPoint.self, from: data) {
            lon = geo.coordinates[0]
            lat = geo.coordinates[1]
        }

        let mediaJSON = (try? cursor.getStringOptional(name: "media_url")) ?? "[]"
        let mediaIds = parseJSONStringArray(mediaJSON ?? "[]")

        let localMediaJSON = (try? cursor.getStringOptional(name: "local_media_identifiers")) ?? "[]"
        let localIds = parseJSONStringArray(localMediaJSON ?? "[]")

        self.init(
            id: id,
            name: name,
            description: (try? cursor.getStringOptional(name: "description")) ?? "",
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            spotTypeId: (try? cursor.getStringOptional(name: "spot_type_id")).flatMap { $0 }.flatMap(UUID.init),
            missionId: (try? cursor.getStringOptional(name: "mission_id")).flatMap { $0 }.flatMap(UUID.init),
            capturedByStaffId: (try? cursor.getStringOptional(name: "captured_by_staff_id")).flatMap { $0 }.flatMap(UUID.init),
            createdBy: createdBy,
            createdAt: createdAt,
            mediaAttachmentIds: mediaIds,
            localMediaIdentifiers: localIds,
            parkId: parkId,
            isResolved: ((try? cursor.getIntOptional(name: "is_resolved")) ?? 0) == 1,
            resolvedAt: SystemManager.parseDate((try? cursor.getStringOptional(name: "resolved_at")) ?? nil),
            resolvedBy: (try? cursor.getStringOptional(name: "resolved_by")).flatMap { $0 }.flatMap(UUID.init),
            severity: Severity(rawValue: (try? cursor.getStringOptional(name: "severity")) ?? "medium") ?? .medium
        )
    }
}

// MARK: - PowerSync row → Incident

extension Incident {
    init?(row: [String: String?]) {
        guard
            let idStr = row["id"] as? String, let id = UUID(uuidString: idStr),
            let name = row["name"] as? String,
            let createdByStr = row["created_by"] as? String, let createdBy = UUID(uuidString: createdByStr),
            let createdAtStr = row["created_at"] as? String, let createdAt = SystemManager.parseDate(createdAtStr),
            let parkStr = row["park_id"] as? String, let parkId = UUID(uuidString: parkStr)
        else { return nil }

        let geometryJSON = row["geometry"] as? String ?? "{}"
        var lat = 0.0, lon = 0.0
        if let data = geometryJSON.data(using: .utf8),
           let geo = try? JSONDecoder().decode(GeoJSONPoint.self, from: data) {
            lon = geo.coordinates[0]
            lat = geo.coordinates[1]
        }

        let mediaJSON = row["media_url"] as? String ?? "[]"
        let mediaIds = parseJSONStringArray(mediaJSON)

        let localMediaJSON = row["local_media_identifiers"] as? String ?? "[]"
        let localIds = parseJSONStringArray(localMediaJSON)

        self.init(
            id: id,
            name: name,
            description: row["description"] as? String ?? "",
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            spotTypeId: (row["spot_type_id"] as? String).flatMap(UUID.init),
            missionId: (row["mission_id"] as? String).flatMap(UUID.init),
            capturedByStaffId: (row["captured_by_staff_id"] as? String).flatMap(UUID.init),
            createdBy: createdBy,
            createdAt: createdAt,
            mediaAttachmentIds: mediaIds,
            localMediaIdentifiers: localIds,
            parkId: parkId,
            isResolved: (row["is_resolved"] as? String) == "1",
            resolvedAt: SystemManager.parseDate(row["resolved_at"] as? String),
            resolvedBy: (row["resolved_by"] as? String).flatMap(UUID.init),
            severity: Severity(rawValue: row["severity"] as? String ?? "medium") ?? .medium
        )
    }
}

// MARK: - GeoJSON helpers

/// Parses both JSON arrays `["a","b"]` and PostgreSQL array literals `{"a","b"}`.
private func parseJSONStringArray(_ raw: String) -> [String] {
    let s = raw.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("[") {
        return (try? JSONDecoder().decode([String].self, from: Data(s.utf8))) ?? []
    }
    if s.hasPrefix("{") && s.hasSuffix("}") {
        // Strip braces, split on commas, remove surrounding quotes
        let inner = String(s.dropFirst().dropLast())
        return inner.components(separatedBy: ",").compactMap { token -> String? in
            let t = token.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\"") && t.hasSuffix("\"") {
                return String(t.dropFirst().dropLast())
            }
            return t.isEmpty ? nil : t
        }
    }
    return []
}

struct GeoJSONPoint: Codable {
    let type: String
    let coordinates: [Double]   // [longitude, latitude]
}

struct GeoJSONGeometry: Codable {
    let type: String
    let coordinates: [[Double]] // polygon ring
}

extension Incident: Equatable {
    static func == (lhs: Incident, rhs: Incident) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.description == rhs.description &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.spotTypeId == rhs.spotTypeId &&
        lhs.missionId == rhs.missionId &&
        lhs.capturedByStaffId == rhs.capturedByStaffId &&
        lhs.createdBy == rhs.createdBy &&
        lhs.createdAt == rhs.createdAt &&
        lhs.mediaAttachmentIds == rhs.mediaAttachmentIds &&
        lhs.localMediaIdentifiers == rhs.localMediaIdentifiers &&
        lhs.parkId == rhs.parkId &&
        lhs.isResolved == rhs.isResolved &&
        lhs.resolvedAt == rhs.resolvedAt &&
        lhs.resolvedBy == rhs.resolvedBy &&
        lhs.severity == rhs.severity
    }
}
