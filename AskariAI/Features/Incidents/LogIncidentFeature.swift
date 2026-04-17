import ComposableArchitecture
import CoreLocation
import Photos
import SwiftUI
import UIKit

// MARK: - LogIncidentFeature

@Reducer
struct LogIncidentFeature {
    @Dependency(\.systemManager) var systemManager

    @ObservableState
    struct State: Equatable {
        var coordinate: CLLocationCoordinate2D
        var selectedSpotTypeId: UUID? = nil
        var description: String = ""
        var severity: Incident.Severity = .medium
        var spotTypes: [SpotType] = []
        var isSaving = false
        var errorMessage: String? = nil
        var mediaItems: [MediaItem] = []
        var showingMediaPicker = false
        var imagePickerSourceType: UIImagePickerController.SourceType = .camera

        // Voice notes
        var sttModelAvailable: Bool = false
        var noteVoiceState: NoteVoiceState = .idle
        var noteTranscriptionPreview: String = ""

        enum NoteVoiceState: Equatable {
            case idle
            case loadingSTT   // downloading whisper model
            case recording
            case transcribing // final STT pass after mic stop
        }

        // CLLocationCoordinate2D doesn't conform to Equatable
        static func == (lhs: State, rhs: State) -> Bool {
            lhs.coordinate.latitude == rhs.coordinate.latitude &&
            lhs.coordinate.longitude == rhs.coordinate.longitude &&
            lhs.selectedSpotTypeId == rhs.selectedSpotTypeId &&
            lhs.description == rhs.description &&
            lhs.severity == rhs.severity &&
            lhs.spotTypes == rhs.spotTypes &&
            lhs.isSaving == rhs.isSaving &&
            lhs.errorMessage == rhs.errorMessage &&
            lhs.mediaItems == rhs.mediaItems &&
            lhs.showingMediaPicker == rhs.showingMediaPicker &&
            lhs.noteVoiceState == rhs.noteVoiceState &&
            lhs.noteTranscriptionPreview == rhs.noteTranscriptionPreview &&
            lhs.sttModelAvailable == rhs.sttModelAvailable
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case spotTypesLoaded([SpotType])
        case showCamera
        case showPhotoLibrary
        case mediaAdded(MediaItem)
        case removeMedia(Int)
        case dismissMediaPicker
        case save
        case saved
        case cancel
        case setError(String?)
        // Voice notes
        case noteMicTapped
        case noteSTTReady
        case sttModelChecked(Bool)
        case noteTranscriptionUpdated(String)
        case noteVoiceTranscribed(String)
    }

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .run { send in
                    // Synchronous disk check — no network, no delay.
                    let available = await AIManager.shared.isSTTModelDownloaded()
                    await send(.sttModelChecked(available))
                    let types = try await systemManager.db.getAll(
                        sql: "SELECT * FROM spot_types WHERE is_active = 1 ORDER BY sort_order",
                        parameters: [],
                        mapper: { cursor in SpotType(cursor: cursor) }
                    )
                    await send(.spotTypesLoaded(types.compactMap { $0 }))
                }

            case .spotTypesLoaded(let types):
                state.spotTypes = types
                if state.selectedSpotTypeId == nil {
                    state.selectedSpotTypeId = types.first?.id
                }
                return .none

            case .save:
                guard let spotType = state.spotTypes.first(where: { $0.id == state.selectedSpotTypeId })
                        ?? state.spotTypes.first else {
                    state.errorMessage = "Please select an incident type."
                    return .none
                }

                state.isSaving = true
                state.errorMessage = nil

                let coordinate = state.coordinate
                let description = state.description
                let severity = state.severity
                let mediaItems = state.mediaItems

                return .run { send in
                    do {
                        // Get current user & park
                        guard let staff = try await systemManager.connector.fetchCurrentStaff() else {
                            await send(.setError("Could not identify current ranger."))
                            return
                        }

                        let parkId: UUID
                        if let pid = staff.parkId {
                            parkId = pid
                        } else {
                            // Fall back: use first park in local DB
                            let parks = try await systemManager.db.getAll(
                                sql: "SELECT id FROM parks LIMIT 1",
                                parameters: [],
                                mapper: { cursor in (try? cursor.getString(name: "id")).flatMap(UUID.init) }
                            )
                            guard let firstPark = parks.first.flatMap({ $0 }) else {
                                await send(.setError("No park found. Ensure data has synced."))
                                return
                            }
                            parkId = firstPark
                        }

                        // Upload media items — collect PowerSync attachment IDs + PhotoKit IDs
                        var attachmentIds: [String] = []
                        var localIdentifiers: [String] = []
                        for item in mediaItems {
                            // Step 1: Save to PowerSync AttachmentQueue (primary)
                            var attachmentId: String? = nil
                            if let queue = systemManager.attachments,
                               let attachment = try? await queue.saveFile(
                                data: item.data,
                                mediaType: item.mimeType,
                                fileExtension: item.fileExtension,
                                updateHook: { _, _ in }
                               ) {
                                attachmentId = attachment.id
                            }
                            guard let aid = attachmentId else { continue }
                            attachmentIds.append(aid)

                            // Step 2: Best-effort save to device Photo Library (fallback)
                            let localId = await saveToPhotoLibrary(item: item)
                            localIdentifiers.append(localId ?? "")
                        }

                        let mediaJSON: String
                        if let encoded = try? JSONEncoder().encode(attachmentIds),
                           let str = String(data: encoded, encoding: .utf8) {
                            mediaJSON = str
                        } else {
                            mediaJSON = "[]"
                        }

                        let localMediaJSON: String
                        if let encoded = try? JSONEncoder().encode(localIdentifiers),
                           let str = String(data: encoded, encoding: .utf8) {
                            localMediaJSON = str
                        } else {
                            localMediaJSON = "[]"
                        }

                        let incidentId = UUID()
                        let geoJSON = "{\"type\":\"Point\",\"coordinates\":[\(coordinate.longitude),\(coordinate.latitude)]}"

                        // PowerSync local write — syncs to Supabase via uploadData
                        let nowISO = SystemManager.isoString(from: Date())

                        try await systemManager.db.execute(
                            sql: """
                                INSERT INTO map_features
                                    (id, park_id, spot_type_id, name, description,
                                     geometry, created_by, captured_by_staff_id,
                                     severity, media_url, local_media_identifiers,
                                     is_resolved, created_at, updated_at)
                                VALUES (?,?,?,?,?,?,?,?,?,?,?,0,?,?)
                            """,
                            parameters: [
                                incidentId.uuidString,
                                parkId.uuidString,
                                spotType.id.uuidString,
                                spotType.displayName,
                                description,
                                geoJSON,
                                staff.id.uuidString,
                                staff.id.uuidString,
                                severity.rawValue,
                                mediaJSON,
                                localMediaJSON,
                                nowISO,
                                nowISO
                            ]
                        )
                        await send(.saved)
                    } catch {
                        await send(.setError(error.localizedDescription))
                    }
                }

            case .showCamera:
                state.imagePickerSourceType = .camera
                state.showingMediaPicker = true
                return .none

            case .showPhotoLibrary:
                state.imagePickerSourceType = .photoLibrary
                state.showingMediaPicker = true
                return .none

            case .mediaAdded(let item):
                state.mediaItems.append(item)
                state.showingMediaPicker = false
                return .none

            case .removeMedia(let index):
                guard index < state.mediaItems.count else { return .none }
                state.mediaItems.remove(at: index)
                return .none

            case .dismissMediaPicker:
                state.showingMediaPicker = false
                return .none

            case .setError(let msg):
                state.isSaving = false
                state.errorMessage = msg
                return .none

            case .saved:
                state.isSaving = false
                return .none

            // MARK: Voice Notes

            case .noteSTTReady:
                state.sttModelAvailable = true  // model is now on disk
                state.noteVoiceState = .recording
                state.noteTranscriptionPreview = ""
                return .run { send in
                    do {
                        try await AIManager.shared.startNoteRecording()
                    } catch {
                        // Recording failed to start — reset silently
                        await send(.noteVoiceTranscribed(""))
                    }
                }

            case .noteMicTapped:
                switch state.noteVoiceState {
                case .idle:
                    state.noteVoiceState = .loadingSTT
                    return .run { send in
                        try? await AIManager.shared.loadSTTIfNeeded()
                        await send(.noteSTTReady)
                    }
                case .recording:
                    state.noteVoiceState = .transcribing
                    state.noteTranscriptionPreview = ""
                    return .run { send in
                        let text = await AIManager.shared.stopNoteRecording()
                        await send(.noteVoiceTranscribed(text))
                    }
                default:
                    return .none
                }

            case .sttModelChecked(let available):
                state.sttModelAvailable = available
                return .none

            case .noteTranscriptionUpdated(let partial):
                state.noteTranscriptionPreview = partial
                return .none

            case .noteVoiceTranscribed(let text):
                if !text.isEmpty {
                    let separator = state.description.isEmpty ? "" : " "
                    state.description += separator + text
                }
                state.noteVoiceState = .idle
                state.noteTranscriptionPreview = ""
                return .none

            case .cancel, .binding:
                return .none
            }
        }
    }
}

// MARK: - PhotoKit helper

/// Best-effort save to device photo library. Returns the PHAsset localIdentifier.
/// Non-fatal: returns nil on permission denial or any error.
private func saveToPhotoLibrary(item: MediaItem) async -> String? {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else { return nil }

    return await withCheckedContinuation { continuation in
        var localId: String? = nil
        PHPhotoLibrary.shared().performChanges({
            switch item {
            case .image(let data):
                if let image = UIImage(data: data) {
                    localId = PHAssetChangeRequest.creationRequestForAsset(from: image)
                        .placeholderForCreatedAsset?.localIdentifier
                }
            case .video(_, let url):
                guard let url else { return }
                localId = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)?
                    .placeholderForCreatedAsset?.localIdentifier
            }
        }, completionHandler: { success, _ in
            continuation.resume(returning: success ? localId : nil)
        })
    }
}

// MARK: - LogIncidentSheet

struct LogIncidentSheet: View {
    @Bindable var store: StoreOf<LogIncidentFeature>

    var body: some View {
        NavigationStack {
            Form {
                Section("Location") {
                    HStack {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundColor(.red)
                        Text(String(format: "%.5f, %.5f",
                                    store.coordinate.latitude,
                                    store.coordinate.longitude))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }

                Section("Incident Type") {
                    if store.spotTypes.isEmpty {
                        ProgressView("Loading types…")
                    } else {
                        Picker("Type", selection: $store.selectedSpotTypeId) {
                            ForEach(store.spotTypes) { spotType in
                                Text(spotType.displayName)
                                    .tag(Optional(spotType.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section("Severity") {
                    Picker("Severity", selection: $store.severity) {
                        ForEach(Incident.Severity.allCases, id: \.self) { s in
                            Text(s.rawValue.capitalized).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Notes") {
                    TextField("Describe what you observed…",
                              text: $store.description,
                              axis: .vertical)
                        .lineLimit(4...)

                    HStack {
                        Spacer()
                        Button {
                            store.send(.noteMicTapped)
                        } label: {
                            switch store.noteVoiceState {
                            case .idle:
                                if store.sttModelAvailable {
                                    Label("Dictate", systemImage: "mic")
                                        .font(.subheadline)
                                } else {
                                    Label("Enable & Dictate", systemImage: "mic.badge.plus")
                                        .font(.subheadline)
                                }
                            case .loadingSTT:
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.8)
                                    Text("Loading…").font(.caption)
                                }
                            case .recording:
                                Label("Stop", systemImage: "stop.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                            case .transcribing:
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.8)
                                    Text("Transcribing…").font(.caption)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            store.noteVoiceState == .loadingSTT ||
                            store.noteVoiceState == .transcribing
                        )
                    }

                    if !store.noteTranscriptionPreview.isEmpty {
                        Text(store.noteTranscriptionPreview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !store.sttModelAvailable && store.noteVoiceState == .idle {
                        Text("Voice dictation requires speech recognition permission. Tap to enable.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Evidence") {
                    if !store.mediaItems.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(store.mediaItems.enumerated()), id: \.offset) { index, item in
                                    ZStack(alignment: .topTrailing) {
                                        if item.isVideo {
                                            ZStack {
                                                Color.black
                                                Image(systemName: "video.fill")
                                                    .foregroundColor(.white)
                                                    .font(.title2)
                                            }
                                            .frame(width: 80, height: 80)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        } else if let uiImage = UIImage(data: item.data) {
                                            Image(uiImage: uiImage)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 80, height: 80)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                        }
                                        Button {
                                            store.send(.removeMedia(index))
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.white, .black.opacity(0.6))
                                                .font(.headline)
                                        }
                                        .offset(x: 4, y: -4)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    HStack(spacing: 16) {
                        Button {
                            store.send(.showCamera)
                        } label: {
                            Label("Camera", systemImage: "camera.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isSaving)

                        Button {
                            store.send(.showPhotoLibrary)
                        } label: {
                            Label("Library", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isSaving)
                    }
                }

                if let error = store.errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Log Incident")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.cancel) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        store.send(.save)
                    } label: {
                        if store.isSaving {
                            ProgressView()
                        } else {
                            Text("Log")
                                .bold()
                        }
                    }
                    .disabled(store.isSaving || store.selectedSpotTypeId == nil)
                }
            }
            .sheet(isPresented: $store.showingMediaPicker) {
                ImagePickerView(
                    sourceType: store.imagePickerSourceType,
                    mediaTypes: store.imagePickerSourceType == .camera
                        ? ["public.image", "public.movie"]
                        : ["public.image", "public.movie"],
                    onCapture: { item in store.send(.mediaAdded(item)) },
                    onCancel: { store.send(.dismissMediaPicker) }
                )
                .ignoresSafeArea()
            }
            .onAppear { store.send(.onAppear) }
        }
    }
}
