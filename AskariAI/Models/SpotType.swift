import Foundation
import SwiftUI

// MARK: - SpotType

struct SpotType: Identifiable, Equatable, Codable {
    let id: UUID
    var codeName: String
    var displayName: String
    var colorHex: String
    var isActive: Bool
    var sortOrder: Int
    var description: String
    var severityDefault: String

    var color: Color {
        Color(hex: colorHex) ?? .orange
    }
}

// MARK: - Known spot codes (for compile-time safety)

extension SpotType {
    enum KnownCode: String, CaseIterable {
        case snare
        case ditchTrap = "ditch_trap"
        case poacherCamp = "poacher_camp"
        case spentCartridge = "spent_cartridge"
        case arrest
        case carcass
        case poison
        case charcoalKiln = "charcoal_kiln"
        case loggingSite = "logging_site"
        case injuredAnimal = "injured_animal"
        case trackFootprint = "track_footprint"
        case vandalizedFence = "vandalized_fence"
        case suspiciousVehicle = "suspicious_vehicle"
        case campfire
    }
}

// MARK: - PowerSync row → SpotType

extension SpotType {
    init?(row: [String: String?]) {
        guard
            let idStr = row["id"] as? String, let id = UUID(uuidString: idStr),
            let codeName = row["code_name"] as? String,
            let displayName = row["display_name"] as? String
        else { return nil }

        self.id = id
        self.codeName = codeName
        self.displayName = displayName
        self.colorHex = row["color_hex"] as? String ?? "#FF6B00"
        self.isActive = (row["is_active"] as? String) != "0"
        self.sortOrder = Int(row["sort_order"] as? String ?? "0") ?? 0
        self.description = row["description"] as? String ?? ""
        self.severityDefault = row["severity_default"] as? String ?? "medium"
    }
}

// MARK: - Color hex init

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default: return nil
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255, opacity: Double(a)/255)
    }
}
