import PowerSync

// MARK: - Sync Priorities
enum SyncPriority {
    static let critical   = 0  // Park info — first
    static let essential  = 1  // Park blocks — second
    static let important  = 2  // Staff, missions — third
    static let background = 3  // Incidents, tracks — last
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

let missions = Table(
    name: "missions",
    columns: [
        .text("park_id"),
        .text("name"),
        .text("objectives"),
        .text("start_date"),
        .text("end_date"),
        .text("patrol_type"),           // "Fence/Boundary"|"Local"|"Mobile"|"Aerial"|"Waterway"
        .text("status"),                // "current"|"future"|"past"
        .text("mission_state"),         // "not_started"|"active"|"paused"|"completed"
        .text("staff_ids"),             // JSON array of UUID strings
        .text("leader_id"),
        .text("selected_block_ids"),    // JSON array of UUID strings
        .text("created_by"),
        .text("created_at"),
        .text("updated_at"),
    ]
)

let map_features = Table(
    name: "map_features",
    columns: [
        .text("park_id"),
        .text("mission_id"),
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
        .text("resolved_at"),
        .text("resolved_by"),
        .text("severity"),              // "low"|"medium"|"high"|"critical"
    ]
)

let park_blocks = Table(
    name: "park_blocks",
    columns: [
        .text("park_id"),
        .text("block_name"),
        .text("coordinates"),           // JSONB stored as text
        .real("threshold"),
        .real("visibility"),
        .real("rate_of_decay"),
        .text("last_patrolled"),
        .text("created_at"),
        .text("updated_at"),
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

/// mission_track — GPS track per mission/staff (called mission_track in the actual DB)
let mission_track = Table(
    name: "mission_track",
    columns: [
        .text("mission_id"),
        .text("staff_id"),
        .text("path_geometry"),
        .text("coverage_geometry"),
        .real("distance_traveled_km"),
        .text("created_at"),
        .text("updated_at"),
    ]
)

let mission_scores = Table(
    name: "mission_scores",
    columns: [
        .text("mission_id"),
        .real("distance_traveled_km"),
        .real("buffer_points"),
        .real("incident_points"),
        .integer("mission_completed"),
        .text("completed_at"),
        .text("created_at"),
        .text("updated_at"),
    ]
)

let mission_role_types = Table(
    name: "mission_role_types",
    columns: [
        .text("name"),
        .text("description"),
    ]
)

let staff_mission = Table(
    name: "staff_mission",
    columns: [
        .text("staff_id"),
        .text("mission_id"),
        .text("role_type_id"),
        .text("assigned_at"),
    ]
)

let terrains = Table(
    name: "terrains",
    columns: [
        .text("park_id"),
        .text("name"),
        .text("geometry"),
        .text("terrain_type"),
        .text("created_at"),
    ]
)

let filter_presets = Table(
    name: "filter_presets",
    columns: [
        .text("owner_id"),
        .text("name"),
        .text("filters"),               // JSONB
        .text("created_at"),
    ]
)

// MARK: - Schema

let AppSchema = Schema(
    tables: [
        parks,
        staff,
        missions,
        map_features,
        park_blocks,
        park_boundaries,
        spot_types,
        mission_track,
        mission_scores,
        mission_role_types,
        staff_mission,
        terrains,
        filter_presets,
        createAttachmentTable(name: "attachments"),
    ]
)
