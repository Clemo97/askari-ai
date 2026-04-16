# e-Parcs: How Local and Remote Media IDs Are Correlated

This document explains the complete identity model for media files in the app — what IDs are stored, where, and how the app reconciles them when a map pin is tapped to display media.

---

## The Two Parallel Identifiers

Every media file attached to a spot has **two separate identifiers** that are stored side-by-side in the database:

| Identifier | What it is | Where it lives |
|---|---|---|
| **Attachment ID** | A UUID (e.g. `a3f9c...`) assigned by PowerSync's `AttachmentQueue` | `map_features.media_url` |
| **PhotoKit identifier** | A `PHAsset.localIdentifier` (e.g. `71B8B0F2-.../L0/001`) assigned by iOS | `map_features.local_media_identifiers` |

They are correlated **positionally** — i.e. `mediaURLs[0]` matches `localMediaIdentifiers[0]`, `mediaURLs[1]` matches `localMediaIdentifiers[1]`, and so on.

---

## Where Both IDs Are Written

When a ranger saves a spot, `saveMediaAttachment` in `SystemManager.swift` returns a tuple:

```swift
return (attachmentRecord.id, photoLibraryIdentifier)
// ("a3f9c...",  "71B8B0F2-45A8-.../L0/001")
```

`MissionFeature` collects these into two parallel arrays as each file uploads:

```swift
uploadedIds.append(attachmentId)          // → state.mediaURLs
photoLibraryIds.append(photoId)           // → state.localMediaIdentifiers
```

`SystemManager.saveSpot` then writes both arrays to the local PowerSync SQLite database as PostgreSQL text arrays:

```swift
// Inserted into map_features:
// media_url              = {"a3f9c...","b81de..."}
// local_media_identifiers = {"71B8B0F2-...","4A4CB12-..."}
INSERT INTO map_features (
    ..., media_url, local_media_identifiers, ...
)
VALUES (
    ...,
    CAST(? AS text[]),   -- e.g. {"a3f9c...","b81de..."}
    CAST(? AS text[]),   -- e.g. {"71B8B0F2-...","4A4CB12-..."}
    ...
)
```

PowerSync then syncs this row to Supabase. The Supabase `map_features` table therefore holds both columns for every device and every user.

---

## The Third Identity: `attachments` Table

PowerSync also maintains its own `attachments` table in the local SQLite database. Every `AttachmentQueue.saveFile(...)` call inserts a row here:

| Column | Value | Meaning |
|---|---|---|
| `id` | `a3f9c...` | Same UUID as in `map_features.media_url` — the **link** |
| `filename` | `a3f9c....jpg` | `<id>.<ext>` on disk |
| `local_uri` | `/var/mobile/.../attachments/a3f9c....jpg` | Absolute sandbox file path |
| `media_type` | `image/jpeg` or `video/mp4` | MIME type |
| `state` | `0` = queued, `2` = synced | Upload/download state |

The `local_uri` is the concrete file path PowerSync writes and reads. It is **never** the PhotoKit identifier — those are kept entirely in `map_features.local_media_identifiers`.

---

## How `fetchSpots` Pre-Joins Both Tables

When spots are loaded from the database (on map appear, after sync), `SystemManager.fetchSpots()` performs a `LEFT JOIN` between `map_features` and `attachments` using the attachment ID as the join key:

```sql
SELECT 
    mf.*,
    a.local_uri  AS attachment_local_uri,
    a.filename   AS attachment_filename
FROM map_features mf
LEFT JOIN attachments a ON mf.media_url = a.id
```

> **Note:** This `LEFT JOIN` only handles the single-value legacy case where `media_url` is a bare UUID (not an array). For the multi-file array case the JOIN returns nothing useful; the per-item resolution happens lazily at display time via `resolveMediaUrl`.

The mapper reads both columns from `map_features` and parses the three possible array formats for `media_url`:

```swift
// Format 1: JSON array (PowerSync/Supabase write path)
"[\"a3f9c...\",\"b81de...\"]"  →  ["a3f9c...", "b81de..."]

// Format 2: PostgreSQL native array (read back from Postgres)
"{\"a3f9c...\",\"b81de...\"}"  →  ["a3f9c...", "b81de..."]

// Format 3: Single bare string (legacy, pre-multi-media)
"a3f9c..."                      →  ["a3f9c..."]
```

The same three-format parsing is applied to `local_media_identifiers`.

The resulting `Spot` struct carries both parsed arrays:

```swift
struct Spot {
    let mediaURLs: [String]             // attachment IDs (or http URLs for legacy data)
    let localMediaIdentifiers: [String]? // matching PhotoKit IDs, positionally aligned
}
```

---

## What Happens When a Map Pin Is Tapped

Tapping a pin opens `SpotDetailsView` (or `MediaGalleryView`). The view calls:

```swift
await systemManager.resolveMediaUrl(mediaURL, localIdentifier: photoKitIdentifier)
```

for each index `i`, passing `spot.mediaURLs[i]` and `spot.localMediaIdentifiers?[i]` together. This is the reconciliation step — the positional pairing is used here.

`resolveMediaUrl` is an alias for `resolveVideoUrl`, which works through **four cases in priority order**:

---

### Case 1 — No string at all → PhotoKit direct

```
urlString == nil or ""
    └─ localIdentifier provided?
           └─ fetchMediaFromPhotoLibrary(localIdentifier, ...)
                ├─ try image → write to tmp/<attachmentId>.jpg → return path
                └─ try video → copy to tmp/<attachmentId>.mp4 → return path
```

---

### Case 2 — Bare attachment ID (no `http` prefix)

```
urlString = "a3f9c..."
    │
    ├─ getAttachmentLocalPath("a3f9c...")
    │       └─ SELECT local_uri FROM attachments WHERE id = "a3f9c..."
    │          If local_uri exists on disk → return sandbox path ✅
    │
    └─ (sandbox file missing — not yet downloaded / cleared by iOS)
           └─ localIdentifier provided?
                  └─ fetchMediaFromPhotoLibrary(localIdentifier, "a3f9c...")
                       ├─ try image → tmp/a3f9c....jpg → return path ✅
                       └─ try video → tmp/a3f9c....mp4 → return path ✅
           └─ return nil ❌ (not available locally at all)
```

The attachment ID is the **primary** lookup key. The PhotoKit identifier is the **fallback** for when the sandbox file has been cleared or has not yet downloaded on this device.

---

### Case 3 — Full URL that might already be cached locally

```
urlString = "https://xxx.supabase.co/storage/v1/object/public/media/a3f9c....jpg"
    │
    └─ extract filename "a3f9c....jpg"
           └─ SELECT id, local_uri FROM attachments
              WHERE filename = "a3f9c....jpg" OR id = "a3f9c....jpg"
              LIMIT 1
              │
              ├─ local_uri starts with "photokit://"?
              │       → strip prefix, use identifier to fetchMediaFromPhotoLibrary ✅
              │
              └─ local_uri is a sandbox path?
                      → FileManager.fileExists(atPath:) check → return path ✅
```

This handles the offline-fallback path where `saveAttachmentOfflineOnly` stored `photokit://<identifier>` as the `local_uri` instead of a sandbox path.

---

### Case 4 — Supabase public/signed URL (fully remote)

```
urlString contains ".supabase.co/storage/v1/object/public/"
    │
    └─ extract bucket-relative path (e.g. "media/a3f9c....jpg")
           └─ bucket.createSignedURL(path:, expiresIn: 604800)  (7-day TTL)
                  └─ return signed URL string ✅
```

A fresh signed URL is generated rather than using the raw public URL. This handles private buckets and expiring tokens.

---

### Final fallback — return the URL as-is

If none of the above matched (unusual URL format), the original string is returned unchanged and the view's `AsyncImage` or `AVPlayer` will attempt to load it remotely.

---

## The `photokit://` URI — The Offline Bridge

`saveAttachmentOfflineOnly` (the path taken when PowerSync's `saveFile` throws an offline error) stores the PhotoKit identifier inside the `attachments.local_uri` column using a custom URI scheme:

```
local_uri = "photokit://71B8B0F2-45A8-4B63-AA2A-FDB7A1B20D2C/L0/001"
```

This is a non-standard scheme invented solely for this app. When `resolveVideoUrl` reads `local_uri` from the `attachments` table (Case 3 above), it checks:

```swift
if localUri.hasPrefix("photokit://") {
    let identifier = String(localUri.dropFirst("photokit://".count))
    // → fetchMediaFromPhotoLibrary(identifier, ...)
}
```

This means even in the offline path the identity chain is preserved: `map_features.media_url` → `attachments.local_uri` → `photokit://` → `PHAsset.localIdentifier` → temp file.

---

## Full Identity Chain Diagram

```
Spot tapped on map
        │
        ▼
Spot.mediaURLs[i]                 Spot.localMediaIdentifiers[i]
("a3f9c...")                      ("71B8B0F2-...")
        │                                 │
        │   ┌─────────────────────────────┘
        ▼   ▼  (passed together to resolveMediaUrl)
resolveVideoUrl(urlString: "a3f9c...", localIdentifier: "71B8B0F2-...")
        │
        ├─ Case 2: attachment ID
        │       │
        │       ▼
        │   SELECT local_uri FROM attachments WHERE id = "a3f9c..."
        │       │
        │       ├─ local_uri = "/var/.../attachments/a3f9c....jpg"
        │       │       └─ FileManager.fileExists? → return sandbox path ✅
        │       │
        │       └─ no row / file missing
        │               │
        │               ▼
        │           PHAsset.fetchAssets(["71B8B0F2-..."])
        │               │
        │               ├─ image → write to tmp/a3f9c....jpg → return path ✅
        │               └─ video → copy to tmp/a3f9c....mp4 → return path ✅
        │
        └─ (Cases 3 & 4 for http URLs)

        ▼
Resolved path / URL
        │
        ▼
MediaGalleryView detects type:
  .mp4 / .mov suffix → AVPlayer (VideoMediaView)
  otherwise          → UIImage / AsyncImage (ImageMediaView)
```

---

## Key Design Decisions

| Decision | Reason |
|---|---|
| Two parallel arrays (not a merged object) | Keeps the database schema simple — both columns are plain text, no JOIN required at the data layer |
| Positional alignment | Avoids a third junction table; works because upload order is deterministic (sequential loop) |
| Sandbox path is **never** the PhotoKit identifier | PowerSync needs the sandbox path for its upload logic; keeping them separate avoids overwriting PowerSync's state |
| PhotoKit is the fallback, not the primary | PowerSync manages the download/sync lifecycle; PhotoKit is only used when the sandbox file is gone |
| `photokit://` URI in `attachments.local_uri` | Written only in the offline save path; acts as a bridge so the same `resolveVideoUrl` lookup chain works regardless of which save path was taken |
