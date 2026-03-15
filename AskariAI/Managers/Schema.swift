import PowerSync

// MARK: - Sync Priorities
enum SyncPriority {
    static let critical   = 0  // Park boundaries — first
    static let essential  = 1  // Park blocks — second
    static let important  = 2  // Staff, missions — third
    static let background = 3  // Incidents, tracks — last
}

// MARK: - Tables
// Columns reflect the ACTUAL Supabase schema (e-parcs + Askari AI additions).
// All columns are text/real/integer — SQLite types. IDs are lowercase UUID strings.

let staff = Table(
    name: "staff",
    columns: [
        .text("email"),
        .text("staff_number"),
        .text("first_name"),
        .text("last_name"),
        .text("rank"),              // "ranger"|"supervisor"|"park_head"|"admin"|"parks_authority"
        .text("user_id"),           // Supabase Auth UUID
        .text("photo_url"),
        .text("created_at"),
    ]
)

let missions = Table(
    name: "missions",
    columns: [
        .text("name"),
        .text("objectives"),
        .text("start_date"),
        .text("end_date"),
        .text("patrol_type"),           // "Fence/Boundary"|"Local"|"Mobile"|"Aerial"|"Waterway"
        .text("status"),                // "current"|"future"|"past"
        .text("mission_state"),         // "not_started"|"active"|"paused"|"completed"
        .text("staff_ids"),             // JSON array of UUID strings
        .text("leader_id"),
        .text("selected_block_ids"),    // JSON array of UUID strings (added by Askari AI)
        .text("user_id"),               // creator's auth UUID
        .text("created_at"),
        .text("updated_at"),
        .text("patrol_actions"),
        .text("route_points"),          // JSONB
        .text("instruction_video_url"),
        .real("total_active_time"),
        .text("last_state_change"),
    ]
)

let map_features = Table(
    name: "map_features",
    columns: [
        .text("name"),
        .text("description"),
        .text("geometry"),              // GeoJSON {type, coordinates}
        .text("created_by"),
        .text("captured_by_staff_id"),
        .text("created_at"),
        .text("updated_at"),
        .text("media_url"),
        .text("mission_id"),
        .text("spot_type_id"),          // FK to spot_types (added by Askari AI)
        .integer("is_resolved"),        // 0 | 1 (added by Askari AI)
        .text("resolved_at"),
        .text("resolved_by"),
        .text("severity"),              // "low"|"medium"|"high"|"critical"
        .real("decay_rate"),
        .real("threshold"),
        .real("buffer_distance"),
        .text("last_patrolled"),
        .text("local_media_identifiers"), // stored as JSON text
    ]
)

let park_blocks = Table(
    name: "park_blocks",
    columns: [
        .text("block_name"),
        .text("coordinates"),           // JSON [[lon,lat],...] stored as text
        .real("threshold"),
        .real("visibility"),
        .real("rate_of_decay"),
        .text("last_patrolled"),
        .text("park_id"),               // FK to park_boundaries
        .text("created_at"),
        .text("updated_at"),
    ]
)

/// park_boundaries is the source of truth for park identity (contains park_name + country)
let park_boundaries = Table(
    name: "park_boundaries",
    columns: [
        .text("park_name"),
        .text("country"),
        .text("coordinates"),           // GeoJSON stored as JSONB → text in SQLite
        .text("created_at"),
        .text("updated_at"),
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

/// green_track is the existing GPS track table (named differently from plan)
let green_track = Table(
    name: "green_track",
    columns: [
        .text("mission_id"),
        .text("geometry"),              // GeoJSON track
        .real("distance_traveled_km"),
        .text("created_at"),
    ]
)

let mission_scores = Table(
    name: "mission_scores",
    columns: [
        .text("mission_id"),
        .real("distance_traveled_km"),
        .real("buffer_points"),
        .integer("mission_completed"),  // 0 | 1
        .text("completed_at"),
        .text("created_at"),
        .text("updated_at"),
    ]
)

let mission_role_types = Table(
    name: "mission_role_types",
    columns: [
        .text("role_name"),
        .text("user_id"),
    ]
)

let staff_mission = Table(
    name: "staff_mission",
    columns: [
        .text("staff_id"),
        .text("mission_id"),
        .text("staff_mission_role"),    // role UUID
        .text("user_id"),
    ]
)

let map_features_missions = Table(
    name: "map_features_missions",
    columns: [
        .text("map_feature_id"),
        .text("mission_id"),
    ]
)

let terrains = Table(
    name: "terrains",
    columns: [
        .text("name"),
        .text("geometry"),
        .text("terrain_type"),
        .text("created_at"),
    ]
)

let filter_presets = Table(
    name: "filter_presets",
    columns: [
        .text("name"),
        .text("description"),
        .text("spot_types"),            // JSON array
        .integer("is_system_preset"),
        .text("created_by"),
        .text("created_at"),
        .text("updated_at"),
        .integer("days_back"),
    ]
)

// MARK: - Schema

let AppSchema = Schema(
    tables: [
        staff,
        missions,
        map_features,
        park_blocks,
        park_boundaries,
        spot_types,
        green_track,
        mission_scores,
        mission_role_types,
        staff_mission,
        map_features_missions,
        terrains,
        filter_presets,
        createAttachmentTable(name: "attachments"),
    ]
)
