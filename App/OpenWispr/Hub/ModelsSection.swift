import OpenWisprCore
import SwiftUI

/// Recommended models and the ones the user added, grouped by task, with downloads.
struct ModelsSection: View {
    @Environment(AppModel.self) private var model
    @State private var notice: String?

    var body: some View {
        let library = model.models.library
        Section {
            ForEach(ModelTask.allCases, id: \.self) { task in
                let statuses = library.models.filter { $0.model.task == task }
                if !statuses.isEmpty {
                    Text(task.title).font(.headline).padding(.top, 4)
                    ForEach(statuses) { status in
                        ModelRow(status: status, selectedFor: selectedRole(status.model.id)) { remove(status) }
                    }
                }
            }
            if !model.models.cachedModels.isEmpty { CachedModels(found: model.models.cachedModels) }
            AddFromHub()
        } header: {
            Text("Built-in models")
        } footer: {
            Text("Recommended models, and any you add, run on this Mac and are downloaded from Hugging Face, reusing any files already in your Hugging Face cache. Downloaded models use \(Format.bytes(library.diskUsageBytes)) on disk.\(notice.map { " \($0)" } ?? "")")
        }
        .task { await model.models.refreshCachedModels() }
    }

    /// The role a downloaded model is selected for, if any; it can't be removed while selected.
    private func selectedRole(_ id: String) -> ModelRole? {
        ModelRole.allCases.first { model.store.settings[$0].builtInModelId == id }
    }

    private func remove(_ status: ModelStatus) {
        Task {
            do {
                let bytes = try await model.models.removeModel(status.model.id)
                notice = "Removed \(status.model.name), freeing \(Format.bytes(bytes))."
            } catch {
                notice = "Couldn’t remove \(status.model.name): \(errorMessage(error))"
            }
        }
    }
}

private struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let status: ModelStatus
    let selectedFor: ModelRole?
    let onRemove: () -> Void

    var body: some View {
        let entry = status.model
        LabeledContent {
            actions
        } label: {
            HStack(spacing: 6) {
                Text(entry.name)
                if let selectedFor { Badge(text: "In use for \(selectedFor.name)", tone: .ok) }
                if status.userAdded { Badge(text: "Added by you") }
                if status.oversized { Badge(text: "Needs more memory than this Mac can spare", tone: .warn) }
            }
            Text("\(Format.bytes(entry.sizeBytes)) download · \(Format.bytes(entry.memoryBytes)) memory · \(entry.speed.label) · \(entry.languages)")
            details
        }
        .accessibilityIdentifier("model-\(entry.id)")
    }

    @ViewBuilder
    private var details: some View {
        switch status.state {
        case .notDownloaded:
            EmptyView()
        case .installed:
            if status.preparing { Text("Preparing for this Mac… The first load compiles it and can take a couple of minutes.") }
        case let .downloading(done, total, speed):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("\(Format.percent(done, total))%\(speed > 0 ? " · \(Format.bytes(Int64(speed)))/s" : "") · \(Format.bytes(total - done)) left")
            }
        case let .paused(done, total, error):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("Paused at \(Format.percent(done, total))%")
                if let error { ErrorText(error) }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        let entry = status.model
        switch status.state {
        case .notDownloaded:
            Button("Download") { Task { try? await model.models.download(entry.id) } }
        case .downloading:
            Button("Cancel", role: .destructive) { Task { try? await model.models.cancelDownload(entry.id) } }
        case .paused:
            HStack {
                Button("Discard", role: .destructive) { Task { try? await model.models.cancelDownload(entry.id) } }.buttonStyle(.link)
                Button("Resume") { Task { try? await model.models.download(entry.id) } }
            }
        case let .installed(size):
            HStack {
                Badge(text: "Installed · \(Format.bytes(size))", tone: .ok)
                if selectedFor == nil, let role = ModelRole(entry.task), entry.isRunnable {
                    Button("Use for \(role.name)") { model.updateSelection(role, .builtIn(modelId: entry.id)) }
                }
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.link)
                    .disabled(selectedFor != nil)
                    .help(selectedFor.map { "Choose another \($0.name) model to remove it" } ?? "")
            }
        }
    }
}

/// Runnable models already in the Hugging Face cache, added in one click without a download.
private struct CachedModels: View {
    @Environment(AppModel.self) private var model
    let found: [CachedModel]
    @State private var adding: Set<String> = []
    @State private var notice: String?

    var body: some View {
        Text("Found in your Hugging Face cache").font(.headline).padding(.top, 4)
        Text("These are already on this Mac, so adding one copies its files from the cache instead of downloading them.")
            .font(.callout).foregroundStyle(.secondary)
        ForEach(found) { cached in
            let entry = cached.model
            LabeledContent {
                Button(adding.contains(entry.id) ? "Adding…" : "Add") { add(entry) }
                    .disabled(adding.contains(entry.id))
                    .accessibilityIdentifier("cached-add-\(entry.id)")
            } label: {
                HStack(spacing: 6) {
                    Text(entry.name)
                    if cached.oversized { Badge(text: "Needs more memory than this Mac can spare", tone: .warn) }
                }
                Text("\(entry.task.title) · \(cached.summary) · \(Format.bytes(entry.sizeBytes)) on disk · about \(Format.bytes(entry.memoryBytes)) memory · \(entry.speed.label) · \(entry.languages)")
            }
            .accessibilityIdentifier("cached-\(entry.id)")
        }
        if let notice { ErrorText(notice) }
    }

    private func add(_ entry: ModelEntry) {
        adding.insert(entry.id)
        notice = nil
        Task {
            do {
                try await model.models.addModel(entry)
            } catch {
                notice = "Couldn’t add \(entry.name): \(errorMessage(error))"
            }
            adding.remove(entry.id)
        }
    }
}

/// Checks a pasted repo id or URL before anything is downloaded, then downloads it as a user-added model.
private struct AddFromHub: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var check: RepoCheck?
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add from Hugging Face").font(.headline)
            Text(
                "Paste a repo id or URL. OpenWispr checks that it can run the model before downloading anything: MLX chat and vision models, "
                    + "and WhisperKit, Parakeet or OpenAI Whisper (like openai/whisper-small.en) speech-to-text models."
            )
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("", text: $input, prompt: Text(verbatim: "mlx-community/Qwen3-4B-Instruct-2507-4bit"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { run(input) }
                    .accessibilityIdentifier("hub-repo")
                Button(busy && check == nil ? "Checking…" : "Check") { run(input) }
                    .disabled(busy || input.trimmed.isEmpty)
                    .accessibilityIdentifier("hub-check")
            }
            if let check { result(check) }
            if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func result(_ check: RepoCheck) -> some View {
        switch check {
        case let .compatible(entry, summary, oversized):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.name).bold()
                    Badge(text: "Compatible", tone: .ok)
                    if oversized { Badge(text: "Needs more memory than this Mac can spare", tone: .warn) }
                }
                Text("\(entry.task.title) · \(summary) · \(Format.bytes(entry.sizeBytes)) download · about \(Format.bytes(entry.memoryBytes)) memory · \(entry.speed.label) · \(entry.languages)")
                    .font(.callout).foregroundStyle(.secondary)
                if !entry.isRunnable { Text("It can be downloaded now and selected once Lens ships.").font(.callout).foregroundStyle(.secondary) }
                Button("Download") { add(entry) }.disabled(busy)
            }
        case let .severalModels(repo, revision, folders, message):
            Picker("\(message):", selection: Binding<String?>(get: { nil }, set: { folder in
                if let folder { run("https://huggingface.co/\(repo)/tree/\(revision)/\(folder)") }
            })) {
                Text("Choose a model folder").tag(String?.none)
                ForEach(folders, id: \.self) { Text($0).tag(String?.some($0)) }
            }
        case let .rejected(_, message):
            ErrorText("\(message).").accessibilityIdentifier("hub-rejected")
        }
    }

    private func run(_ value: String) {
        guard !value.trimmed.isEmpty else { return }
        input = value
        notice = nil
        check = nil
        busy = true
        Task {
            check = await model.models.checkRepo(value)
            busy = false
        }
    }

    private func add(_ entry: ModelEntry) {
        busy = true
        check = nil
        input = ""
        notice = "Downloading \(entry.name); it’s listed under \(entry.task.title) as added by you."
        Task {
            do {
                try await model.models.addModel(entry)
            } catch {
                notice = "Couldn’t download \(entry.name): \(errorMessage(error))"
            }
            busy = false
        }
    }
}

extension ModelRole {
    /// The role a model of `task` can be selected for; vision models have none yet.
    init?(_ task: ModelTask) {
        switch task {
        case .speechToText: self = .speechToText
        case .chat: self = .chat
        case .vision: return nil
        }
    }
}

extension ModelTask {
    var title: String {
        switch self {
        case .speechToText: "Speech-to-text"
        case .chat: "Chat"
        case .vision: "Vision (for Lens later)"
        }
    }
}
