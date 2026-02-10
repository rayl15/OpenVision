// OpenVision - MemoriesView.swift
// AI memories management (key-value pairs)

import SwiftUI

struct MemoriesView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager

    // MARK: - State

    @State private var selectedMemory: (key: String, value: String)?
    @State private var showingEditor: Bool = false
    @State private var showingDeleteConfirmation: Bool = false
    @State private var memoryToDelete: String?

    // MARK: - Body

    var body: some View {
        List {
            if settingsManager.settings.memories.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "brain")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)

                        Text("No memories yet")
                            .font(.headline)

                        Text("The AI can add memories during conversations, or you can add them manually.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            } else {
                Section {
                    ForEach(sortedMemoryKeys, id: \.self) { key in
                        Button {
                            selectedMemory = (key: key, value: settingsManager.settings.memories[key] ?? "")
                            showingEditor = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(key)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)

                                Text(settingsManager.settings.memories[key] ?? "")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                memoryToDelete = key
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Stored Memories")
                } footer: {
                    Text("\(settingsManager.settings.memories.count) memories")
                }
            }
        }
        .navigationTitle("Memories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    selectedMemory = nil
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            MemoryEditorView(
                existingKey: selectedMemory?.key,
                existingValue: selectedMemory?.value ?? ""
            )
        }
        .confirmationDialog(
            "Delete Memory",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let key = memoryToDelete {
                    settingsManager.deleteMemory(key: key)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let key = memoryToDelete {
                Text("Are you sure you want to delete '\(key)'?")
            }
        }
    }

    // MARK: - Computed Properties

    private var sortedMemoryKeys: [String] {
        settingsManager.settings.memories.keys.sorted()
    }
}

// MARK: - Memory Editor View

struct MemoryEditorView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - Properties

    let existingKey: String?
    let existingValue: String

    // MARK: - State

    @State private var key: String = ""
    @State private var value: String = ""
    @State private var showingDeleteConfirmation: Bool = false

    var isNewMemory: Bool { existingKey == nil }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Key")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("user_name", text: $key)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .disabled(!isNewMemory)
                    }
                } header: {
                    Text("Identifier")
                } footer: {
                    Text("A short identifier (e.g., 'user_name', 'favorite_color')")
                }

                Section {
                    TextEditor(text: $value)
                        .frame(minHeight: 100)
                } header: {
                    Text("Value")
                } footer: {
                    Text("The information to remember")
                }

                if !isNewMemory {
                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                Label("Delete Memory", systemImage: "trash")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(isNewMemory ? "New Memory" : "Edit Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveMemory()
                        dismiss()
                    }
                    .disabled(key.isEmpty || value.isEmpty)
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                key = existingKey ?? ""
                value = existingValue
            }
            .confirmationDialog(
                "Delete Memory",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let existingKey {
                        settingsManager.deleteMemory(key: existingKey)
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete this memory?")
            }
        }
    }

    // MARK: - Methods

    private func saveMemory() {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existingKey, existingKey != trimmedKey {
            // Key was renamed
            settingsManager.renameMemory(oldKey: existingKey, newKey: trimmedKey)
        }

        settingsManager.setMemory(key: trimmedKey, value: trimmedValue)
        settingsManager.saveNow()
    }
}

#Preview {
    NavigationStack {
        MemoriesView()
            .environmentObject(SettingsManager.shared)
    }
}
