import Foundation
import PowerSync

// MARK: - Staff Member

struct StaffMember: Identifiable, Equatable, Codable {
    let id: UUID
    var email: String
    var firstName: String
    var lastName: String
    var rank: Rank
    var parkId: UUID?
    var userId: UUID?       // Supabase Auth UUID
    var avatarURL: String?
    var createdAt: Date
    var isActive: Bool

    enum Rank: String, Codable, CaseIterable {
        case ranger
        case supervisor
        case parkHead = "park_head"
        case admin
        case parksAuthority = "parks_authority"
    }

    var fullName: String { "\(firstName) \(lastName)" }

    var userRole: UserRole {
        switch rank {
        case .ranger:          return .ranger
        case .supervisor:      return .ranger      // treated as ranger for UI
        case .parkHead:        return .parkHead
        case .admin:           return .admin
        case .parksAuthority:  return .parksAuthority
        }
    }
}

// MARK: - PowerSync row → StaffMember

extension StaffMember {
    /// Init from a PowerSync `SqlCursor` row.
    init?(cursor: any SqlCursor) {
        guard
            let idStr = try? cursor.getString(name: "id"),
            let id = UUID(uuidString: idStr),
            let email = try? cursor.getString(name: "email"),
            let firstName = try? cursor.getString(name: "first_name"),
            let lastName = try? cursor.getString(name: "last_name"),
            let createdAtStr = try? cursor.getString(name: "created_at"),
            let createdAt = SystemManager.parseDate(createdAtStr)
        else { return nil }

        self.id = id
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.rank = Rank(rawValue: (try? cursor.getString(name: "rank")) ?? "ranger") ?? .ranger
        self.parkId = (try? cursor.getStringOptional(name: "park_id")).flatMap { $0 }.flatMap(UUID.init)
        self.userId = (try? cursor.getStringOptional(name: "user_id")).flatMap { $0 }.flatMap(UUID.init)
        self.avatarURL = (try? cursor.getStringOptional(name: "photo_url")) ?? nil
        self.createdAt = createdAt
        self.isActive = ((try? cursor.getIntOptional(name: "is_active")) ?? 1) != 0
    }

    init?(row: [String: String?]) {
        guard
            let idStr = row["id"] as? String, let id = UUID(uuidString: idStr),
            let email = row["email"] as? String,
            let firstName = row["first_name"] as? String,
            let lastName = row["last_name"] as? String,
            let createdAtStr = row["created_at"] as? String,
            let createdAt = SystemManager.parseDate(createdAtStr)
        else { return nil }

        self.id = id
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.rank = Rank(rawValue: row["rank"] as? String ?? "ranger") ?? .ranger
        self.parkId = (row["park_id"] as? String).flatMap(UUID.init)
        self.userId = (row["user_id"] as? String).flatMap(UUID.init)
        self.avatarURL = row["photo_url"] as? String
        self.createdAt = createdAt
        self.isActive = (row["is_active"] as? String) != "0"
    }
}

// MARK: - User Role (App-level)

enum UserRole: String, Codable, Equatable {
    case admin
    case parkHead
    case ranger
    case parksAuthority

    var displayName: String {
        switch self {
        case .admin:           return "Admin"
        case .parkHead:        return "Park Head"
        case .ranger:          return "Ranger"
        case .parksAuthority:  return "Parks Authority"
        }
    }
}
