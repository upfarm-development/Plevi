import SwiftUI
import PleviDomain

/// Putting a record — or an artist — into one of the server's collections.
struct AddToCollectionView: View {
    let kind: MediaCollection.Kind
    let itemIDs: [MediaID]
    /// What is being filed, for the title — "Add “Blue Train” to…".
    let what: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var fetched = FetchedList<MediaCollection>()
    @State private var working = false
    @State private var newName = ""
    @State private var creating = false
    @State private var problem: String?

    private var candidates: [MediaCollection] {
        (fetched.items ?? []).filter { $0.kind == kind }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newName = ""
                        creating = true
                    } label: {
                        Label("New Collection…", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    // Only once the server has said what is there: a list
                    // that failed to load would offer a duplicate of a
                    // collection that already exists.
                    .disabled(fetched.items == nil)
                }

                if !candidates.isEmpty {
                    Section("Add to") {
                        ForEach(candidates) { collection in
                            Button {
                                Task { await add(to: collection) }
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(
                                        artwork: collection.artwork,
                                        size: CompactList.thumbnailSize,
                                        cornerRadius: 6
                                    )
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(collection.name)
                                            .foregroundStyle(.primary)
                                        if let count = collection.itemCount {
                                            Text(count.counted(kind == .albums ? "album" : "artist"))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if fetched.isLoading || working {
                    ProgressView()
                } else if fetched.isFailed, let failure = fetched.failure {
                    FetchFailureView(message: failure) { Task { await load() } }
                } else if candidates.isEmpty {
                    ContentUnavailableView(
                        "No collections yet",
                        systemImage: "rectangle.stack",
                        description: Text("Make one to put \(what) in it.")
                    )
                }
            }
            .alert("New Collection", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { Task { await create() } }
            } message: {
                Text("A new collection on the server, starting with \(what).")
            }
            .alert("Could not add", isPresented: Binding(
                get: { problem != nil },
                set: { if !$0 { problem = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
            .task { await load() }
        }
        .withoutBottomScrollEdgeBlur()
    }

    private func load() async {
        guard let provider = app.provider else {
            fetched.apply(.failed(message: "Not connected to a server."))
            return
        }
        guard provider.capabilities.contains(.collections) else {
            fetched.apply(.answered([]))
            return
        }
        fetched.beginRetry()
        fetched.apply(await FetchOutcome.attempt { try await provider.collections() })
    }

    private func add(to collection: MediaCollection) async {
        guard let provider = app.provider else { return }
        working = true
        defer { working = false }
        do {
            try await provider.addToCollection(id: collection.id, itemIDs: itemIDs)
            app.showNote("Added to “\(collection.name)”")
            dismiss()
        } catch {
            problem = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            problem = "Give it a name first."
            return
        }
        guard let provider = app.provider else { return }
        working = true
        defer { working = false }
        do {
            let made = try await provider.createCollection(name: name, kind: kind, itemIDs: itemIDs)
            app.showNote("Made “\(made.name)”")
            dismiss()
        } catch {
            problem = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// What is on its way into a collection.
struct CollectionAddition: Identifiable, Hashable {
    let kind: MediaCollection.Kind
    let itemIDs: [MediaID]
    let what: String

    var id: String { itemIDs.map(\.rawValue).joined(separator: ",") + kind.rawValue }
}
