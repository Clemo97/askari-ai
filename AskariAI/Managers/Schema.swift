import PowerSync

// MARK: - Sync Priorities
enum SyncPriority {
    static let critical   = 0  // Park boundaries — load first
    static let essential  = 1  // Reference data — spot types
    static let important  = 2  // Staff, parks — context data
    static let background = 3  // Incidents, media — last
}

// MARK: - Tables
// Columns reflect the ACTUAL Supabase e-parcs schema (verified against DBML).
// All columns are text/real/integer — SQLite types. IDs are lowercase UUID strings.

let parks = Table(
    name: "parks",
    columns: [
        .text("name"),
        .text("country"),
        .text("region"),
        .text("timezone"),
        .text("created_at"),
        .text("updated_at"),
    ]
)

let staff = Table(
    name: "staff",
    columns: [
        .text("user_id"),           // Supabase Auth UUID
        .text("park_id"),
        .text("email"),
        .text("first_name"),
        .text("last_name"),
        .text("rank"),              // "ranger"|"supervisor"|"park_head"|"admin"|"parks_authority"
        .text("avatar_url"),
        .integer("is_active"),
        .text("created_at"),
        .text("updated_at"),
    ]
)
let map_features = Table(
    name: "map_features",
    columns: [
        .text("park_id"),
        .text("spot_type_id"),
        .text("name"),
        .text("description"),
        .text("geometry"),              // GeoJSON {type, coordinates}
        .text("created_by"),
        .text("captured_by_staff_id"),
        .text("created_at"),
        .text("updated_at"),
        .text("media_url"),             // JSONB array of attachment IDs
        .text("local_media_identifiers"), // JSONB array of PhotoKit local identifiers
        .integer("is_resolved"),
        .text("severity"),              // "low"|"medium"|"high"|"critical"
    ]
)

/// park_boundaries — boundary polygons for each park (name/country comes from parks table)
let park_boundaries = Table(
    name: "park_boundaries",
    columns: [
        .text("park_id"),
        .text("name"),
        .text("geometry"),              // GeoJSON stored as JSONB → text in SQLite
        .text("created_at"),
    ]
)

let spot_types = Table(
    name: "spot_types",
    columns: [
        .text("code_name"),
        .text("display_name"),
        .text("color_hex"),
        .integer("is_active"),
        .integer("sort_order"),
        .text("description"),
        .text("severity_default"),
        .text("created_at"),
    ]
)

let mission_role_types = Table(
    name: "mission_role_types",
    columns: [
        .text("name"),
        .text("description"),
    ]
)

// MARK: - Schema

let AppSchema = Schema(
    tables: [
        parks,
        staff,
        map_features,
        park_boundaries,
        spot_types,
        mission_role_types,
        createAttachmentTable(name: "attachments"),
    ]
)
