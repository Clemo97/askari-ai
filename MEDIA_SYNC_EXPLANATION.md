# e-Parcs: Media Synchronization Engine

This document covers the full media pipeline — from camera capture, through PhotoKit storage, to PowerSync's offline-first attachment queue, and finally to Supabase Storage in the cloud.

---

## Overview

The app uses a **dual-storage strategy** for every piece of media a ranger captures:

| Storage layer | Purpose | Persists offline? |
|---|---|---|
| **Device Photo Library (PhotoKit)** | Permanent device backup | ✅ Yes, survives app uninstall / reinstall |
| **PowerSync sandbox + AttachmentQueue** | Cloud sync queue | ✅ Yes, queued until online |
| **Supabase Storage bucket** | Cloud master copy | Online only |

Media never blocks the spot-saving workflow. Capture → save locally → sync cloud in the background.

---

## 1. Permissions

### `PhotoLibraryManager` — `Managers/PhotoLibraryManager.swift`

Two separate permission scopes are managed:

#### Add-only permission (for saving captured media)
```swift
PHPhotoLibrary.requestAuthorization(for: .addOnly)
```
Used when writing an image or video to the device library after capture. The app only requests this at the moment of first save, not upfront.

#### Read-write permission (for retrieving media to display)
```swift
PHPhotoLibrary.requestAuthorization(for: .readWrite)
```
Used when loading an image or video back from the library to show in the media gallery or resolve a cached attachment.

Both methods follow the same pattern:
- If already `.authorized` or `.limited` → return `true` immediately.
- If `.notDetermined` → call `requestAuthorization` and return the result.
- If `.denied` or `.restricted` → return `false` and surface an error.

Neither call blocks the UI — they are `async` and the calling code proceeds only after the result is available.

---

## 2. Distinguishing Photos from Videos

### `MediaItem` enum — `Features/MissionFeature.swift`

```swift
enum MediaItem: Equatable {
    case image(data: Data)
    case video(data: Data, url: URL?)
}
```

This enum is the single source of truth for in-memory media. It carries:
- **`.image(data:)`** — raw JPEG bytes ready to save.
- **`.video(data:url:)`** — raw MP4/MOV bytes plus an optional source `URL` (populated for files from `PHPickerViewController`, `nil` for camera-recorded clips).

Helper computed properties:
```swift
var isVideo: Bool   // true for .video case
var isImage: Bool   // !isVideo
var data: Data      // extracts the bytes from either case
```

This distinction drives everything downstream — which PhotoKit save method is called, which MIME type and file extension is used, and how thumbnails are rendered in the UI.

---

## 3. Capture Flow

### Camera (Photos) — `MissionSpotCaptureView.swift`

```
UIImagePickerController (sourceType: .camera)
    → delegate: imagePickerController(_:didFinishPickingMediaWithInfo:)
    → info[.originalImage] as? UIImage
    → image.jpegData(compressionQuality: 0.8)
    → viewStore.send(.cameraImageCaptured(imageData))
```

### Camera (Videos) — `MissionSpotCaptureView.swift`

```
UIImagePickerController
    (sourceType: .camera, mediaTypes: ["public.movie"], videoQuality: .typeMedium)
    → delegate: didFinishPickingMediaWithInfo
    → info[.mediaURL] as? URL
    → viewStore.send(.cameraVideoCaptured(videoURL))
    → Data(contentsOf: videoURL)
    → viewStore.send(.processVideoFromCamera(videoData))
```

Both routes produce a `MediaItem` value that is appended to `state.mediaItems`.

---

## 4. Image Compression Before Upload

Before any image is added to `state.mediaItems`, it is optionally resized and compressed by `SupabaseManager.resizeAndCompressImage`:

```swift
// SupabaseManager.swift
func resizeAndCompressImage(data: Data) async -> Data? {
    // Max 1024px on the longest side
    let ratio = min(1024 / image.size.width, 1024 / image.size.height)
    // Re-encode as JPEG at 70% quality
    resizedImage.jpegData(compressionQuality: 0.7)
}
```

- Runs on a background `DispatchQueue` (`.userInitiated` QoS), not the main thread.
- If processing fails for any reason, the original data is used as a fallback.
- Videos are **not** compressed — they are stored at `.typeMedium` camera quality.

---

## 5. The Upload Trigger

The ranger presses **Save** in `MissionSpotCaptureView`. The TCA action chain is:

```
.saveSpot
  → if mediaItems is non-empty: .uploadMedia
  → [upload all files sequentially]
  → .uploadAllMediaComplete(attachmentIds, photoLibraryIds)
  → .saveSpot (now with media URLs populated)
```

The `mediaItems` array is looped over in order. For each item:
- If `.image` → `mediaType = "image/jpeg"`, `fileExtension = "jpg"`
- If `.video` → `mediaType = "video/mp4"`, `fileExtension = "mp4"`

Then `systemManager.saveMediaAttachment(data:mediaType:fileExtension:)` is called.

---

## 6. `saveMediaAttachment` — The Two-Step Save

`SystemManager.swift` — `func saveMediaAttachment(...)`

### Step 1: Save to the Device Photo Library

```swift
if fileExtension == "jpg" || fileExtension == "jpeg" || fileExtension == "png" {
    photoLibraryIdentifier = try await PhotoLibraryManager.shared.saveImageToLibrary(imageData: data)
} else if fileExtension == "mp4" || fileExtension == "mov" {
    photoLibraryIdentifier = try await PhotoLibraryManager.shared.saveVideoToLibrary(videoData: data)
}
```

This step is **non-fatal**. If the photo library save fails (e.g., permission denied), a warning is logged and execution continues to Step 2.

**Why save to the photo library?**  
The PowerSync sandbox directory can be cleared by iOS when storage is low. The photo library is a permanent, user-visible backup that survives app reinstalls.

### Step 2: Save to PowerSync AttachmentQueue

```swift
let attachmentRecord = try await attachments.saveFile(
    data: data,
    mediaType: mediaType,
    fileExtension: fileExtension
) { tx, record in
    // callback runs inside the PowerSync transaction
    // we just let it create the record; spot will reference the ID later
}
```

PowerSync:
1. Writes the file bytes to the app's sandbox at `Documents/attachments/<uuid>.<ext>`.
2. Creates a row in the `attachments` SQLite table with `state = QUEUED_UPLOAD`.
3. Returns an `Attachment` record with a stable `id` (a UUID string).
4. When connectivity is available, `AttachmentQueue` automatically calls `SupabaseRemoteStorage.uploadFile` to push the file to Supabase Storage.

### Return value

```swift
return (attachmentRecord.id, photoLibraryIdentifier)
// e.g. ("a3f9c...", "71B8B0F2-...")
```

- `attachmentRecord.id` → stored in `map_features.media_url` as a PowerSync attachment ID.
- `photoLibraryIdentifier` → stored in `map_features.local_media_identifiers` as a PhotoKit `PHAsset.localIdentifier`.

---

## 7. Offline Fallback — `saveAttachmentOfflineOnly`

If `saveMediaAttachment` fails with a network/offline error, a fallback path is taken:

```swift
// Generates a UUID manually
let attachmentId = UUID().uuidString

// Writes the file to the sandbox manually
let filePath = "\(attachmentsDir)/\(attachmentId).\(fileExtension)"
try data.write(to: URL(fileURLWithPath: filePath))

// Chooses what to store in local_uri
let localUri = photoLibraryIdentifier != nil
    ? "photokit://\(photoLibraryIdentifier!)"
    : filePath

// Inserts directly into the attachments table with state = 0 (QUEUED)
db.execute("""
    INSERT INTO attachments (id, filename, media_type, local_uri, state, ...)
    VALUES (?, ?, ?, ?, 0, ...)
""")
```

State `0` means "queued for upload". When PowerSync comes back online and processes its pending upload queue, it will pick up this row and push the file to Supabase.

The `photokit://` URI scheme is a custom convention used only in this fallback path. The next section explains how it is decoded on read.

---

## 8. Database Storage Format

In the PowerSync/Supabase `map_features` table:

| Column | Format | Example |
|---|---|---|
| `media_url` | PostgreSQL text array `{id1,id2}` | `{"a3f9c...", "b81de..."}` |
| `local_media_identifiers` | PostgreSQL text array | `{"71B8B0F2-...", "4A4CB12-..."}` |

**Why PostgreSQL array format?**  
The app comment explains: Supabase's `postgrest` cannot parse JSON arrays `["x"]` in write operations — it requires the PostgreSQL native array literal format `{"x"}`.

On read, `parseStringArrayFromPostgreSQL` in `SystemManager.swift` converts `{"id1","id2"}` back to a Swift `[String]`.

---

## 9. `SupabaseRemoteStorage` — The Cloud Adapter

`Managers/SupabaseRemoteStorage.swift`

This is a thin adapter that connects PowerSync's `AttachmentQueue` to the Supabase Storage SDK:

```swift
func uploadFile(fileData: Data, attachment: PowerSync.Attachment) async throws {
    try await storage.upload(attachment.filename, data: fileData)
}

func downloadFile(attachment: PowerSync.Attachment) async throws -> Data {
    try await storage.download(path: attachment.filename)
}

func deleteFile(attachment: PowerSync.Attachment) async throws {
    _ = try await storage.remove(paths: [attachment.filename])
}
```

The `storage` property is a `Supabase.StorageFileApi` scoped to a specific bucket name (configured via `Secrets.supabaseStorageBucket`). PowerSync calls these methods automatically based on attachment state — the app code never calls them directly.

---

## 10. The AttachmentQueue Watcher

`SystemManager.createAttachmentQueue` — called once during `init()`.

The `watchAttachments` closure is a live SQL query that PowerSync monitors for changes. It tells the queue **which attachment IDs are currently referenced** in the database:

```sql
SELECT json_each.value AS attachment_id,
       CASE
         WHEN lower(json_each.value) LIKE '%.mov' THEN 'mov'
         WHEN lower(json_each.value) LIKE '%.mp4' THEN 'mp4'
         ELSE 'jpg'
       END AS file_ext
FROM map_features, json_each(
    CASE
        WHEN media_url LIKE '[%' THEN media_url          -- JSON array format (legacy)
        WHEN media_url IS NOT NULL AND media_url != '' THEN json_array(media_url)  -- single value
        ELSE '[]'
    END
)
WHERE media_url IS NOT NULL AND media_url != ''
AND json_each.value NOT LIKE 'http%'     -- exclude already-resolved http URLs

UNION ALL

SELECT instruction_video_url AS attachment_id, 'mov' AS file_ext
FROM missions
WHERE instruction_video_url IS NOT NULL
AND instruction_video_url NOT LIKE 'http%'
```

Key points:
- Only rows where `media_url` is an **attachment ID** (not an `http` URL) are watched — IDs that look like `http%` are already on the cloud.
- The `CASE` expression on `file_ext` detects photo vs video by inspecting the ID's suffix (`.mov` / `.mp4` → video, else → image JPEG).
- The `UNION ALL` also watches `missions.instruction_video_url` so admin-uploaded briefing videos are synced too.
- When a new attachment ID appears in `map_features`, `AttachmentQueue` immediately queues it for download on other devices.

---

## 11. Media URL Resolution — `resolveVideoUrl` / `resolveMediaUrl`

When the app needs to display a piece of media (gallery view, spot detail view), it calls:

```swift
systemManager.resolveMediaUrl(mediaURL, localIdentifier: photoKitIdentifier)
```

This runs through **four cases in order**:

### Case 1 — No URL at all
If `urlString` is nil or empty, fall back to the PhotoKit identifier directly (fetch from photo library to a temp file).

### Case 2 — Attachment ID (no `http` prefix)
```swift
if !urlString.hasPrefix("http") {
    // Try the PowerSync attachments table
    if let localPath = try? await getAttachmentLocalPath(attachmentId: urlString) {
        return localPath  // sandbox file path
    }
    // Fallback: PhotoKit
    if let identifier = localIdentifier {
        return try? await fetchMediaFromPhotoLibrary(localIdentifier: identifier, attachmentId: urlString)
    }
    return nil  // not available locally yet
}
```

### Case 3 — URL with a filename we might have locally
```swift
// Extract filename from URL, query attachments table by filename
// If local_uri starts with "photokit://" → fetch from photo library
// Otherwise: verify sandbox file exists and return path
```

### Case 4 — Supabase public/signed URL
```swift
if urlString.contains(".supabase.co/storage/v1/object/public/") {
    // Generate a fresh signed URL valid for 7 days
    let signedURL = try await bucket.createSignedURL(path: filename, expiresIn: 604800)
    return signedURL.absoluteString
}
```

### Fallback
Return the URL string as-is (for any other remote URL format).

---

## 12. `fetchMediaFromPhotoLibrary` — The PhotoKit Read Path

`SystemManager.swift` — private method

```swift
do {
    // Try image first
    let imageData = try await PhotoLibraryManager.shared.fetchImageData(localIdentifier: localIdentifier)
    let tempFile = tempDir.appendingPathComponent("\(attachmentId).jpg")
    try imageData.write(to: tempFile)
    return tempFile.path
} catch {
    // If image fails, try video
    let videoURL = try await PhotoLibraryManager.shared.fetchVideoURL(localIdentifier: localIdentifier)
    let tempFile = tempDir.appendingPathComponent("\(attachmentId).mp4")
    FileManager.default.copyItem(at: videoURL, to: tempFile)
    return tempFile.path
}
```

The method **tries image first, then video** — because a `PHAsset.localIdentifier` doesn't encode its media type. The image path copies data into a temp file; the video path copies the AVURLAsset's URL to the temp directory (DCIM paths are not stable across sessions).

---

## 13. Media Gallery — Type Detection on Playback

`MediaGalleryView.swift` — `detectMediaType(from:)`

Once a URL is resolved, type is detected purely from the string:

```swift
// Video if it ends with known video extensions, or URL contains "video"
if lowercased.hasSuffix(".mp4") || lowercased.hasSuffix(".mov") || ... { return .video }
// Image otherwise (jpg, jpeg, png, etc.)
return .image
```

The gallery renders type-specific views:
- **Images** → `AsyncImage` for remote URLs, `UIImage(contentsOf:)` for local file paths.
- **Videos** → `AVPlayer` initialized with the resolved `URL`. Shows a loading/error overlay based on `AVPlayerItem.Status`.

---

## 14. Instruction Video — Admin Upload Path

Mission briefing videos (uploaded by admins) follow a **different, simpler path** — they bypass PowerSync entirely:

`MissionInstructionsFeature.swift`

```swift
// Save to photo library for local persistence
let identifier = try await PhotoLibraryManager.shared.saveVideoToLibrary(videoData: videoData)

// Upload directly to Supabase Storage "media" bucket
let uploadedURL = try await SupabaseManager.shared.uploadMedia(data: videoData, fileName: fileName)
```

`SupabaseManager.uploadMedia` calls `client.storage.from("media").upload(...)` and returns a **public URL** that is then stored in `missions.instruction_video_url`. There is no offline queuing — this requires active internet.

---

## 15. Sign-Out Cleanup

When a user signs out (`SystemManager.signOut()`):

```swift
try await attachments?.stopSyncing()  // Pause cloud sync
try await attachments?.clearQueue()   // Remove pending upload/download tasks
```

This prevents the attachment queue from running unauthenticated network requests after sign-out; any unsent media remains in the sandbox and will be re-queued on the next sign-in.

---

## Summary Flow Diagram (Ranger Captures a Spot)

```
Ranger presses camera button
        │
        ▼
UIImagePickerController (photo or video)
        │
        ▼
MissionFeature: .cameraImageCaptured / .cameraVideoCaptured
        │
        ├─ image: SupabaseManager.resizeAndCompressImage()
        │         (max 1024px, JPEG 0.7 quality)
        │
        ▼
state.mediaItems.append(MediaItem.image / .video)
        │
User presses Save
        │
        ▼
MissionFeature: .uploadMedia
  loop over mediaItems:
    │
    ├─ determine MIME type + extension
    │   .image → "image/jpeg", "jpg"
    │   .video → "video/mp4", "mp4"
    │
    ▼
  systemManager.saveMediaAttachment(data:mediaType:fileExtension:)
    │
    ├─① PhotoLibraryManager.saveImageToLibrary / saveVideoToLibrary
    │   → returns PHAsset.localIdentifier
    │
    ├─② attachments.saveFile(...)  [PowerSync AttachmentQueue]
    │   → writes file to Documents/attachments/<uuid>.ext
    │   → inserts row into `attachments` table, state = QUEUED_UPLOAD
    │   → returns Attachment.id (UUID string)
    │
    └─ returns (attachmentId, photoLibraryIdentifier)
        │
        ▼
  .uploadAllMediaComplete([attachmentIds], [photoLibraryIds])
        │
        ▼
  .saveSpot
    → db.execute INSERT INTO map_features
        media_url = {"uuid1","uuid2"}           (PowerSync attachment IDs)
        local_media_identifiers = {"pk-id1",..}  (PhotoKit identifiers)
        │
        ▼
  [background — when internet available]
  PowerSync AttachmentQueue watcher detects new IDs in map_features.media_url
  → SupabaseRemoteStorage.uploadFile(fileData:attachment:)
  → Supabase Storage bucket
  → attachment state updated to SYNCED
```
