import SwiftUI
import SwiftData
import OllamaCore
import AVFoundation
import Speech
import PhotosUI

struct ModelSelectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var modelStore = ModelStorage.shared
    @Binding var selectedModel: ModelSnapshot?

    private var availableModels: [ModelSnapshot] {
        BuiltInModelCatalog.selectionModels(downloadedModels: modelStore.selectionSnapshots)
    }

    private var appleAvailability: BuiltInModelAvailability {
        BuiltInModelCatalog.availability()
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedMeshBackground()
                
                List {
                    if availableModels.isEmpty {
                        Section {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 36))
                                    .foregroundStyle(.secondary)

                                Text("No Runnable Models")
                                    .font(.headline)

                                Text("Download a GGUF model, import a full ANEMLL/CoreML model package, or use Apple On-Device AI if available.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .listRowBackground(Color.clear)
                        }
                    } else {
                        ForEach(availableModels) { model in
                            Button {
                                selectedModel = model
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.displayName)
                                            .font(.system(size: 16, weight: .medium))
                                        
                                        HStack(spacing: 8) {
                                            if model.isBuiltInAppleModel {
                                                Label("Built In", systemImage: "apple.logo")
                                                    .font(.system(size: 12))

                                                Text("•")

                                                Label(appleAvailability.isAvailable ? "On Device" : "Unavailable", systemImage: appleAvailability.isAvailable ? "bolt.fill" : "exclamationmark.triangle.fill")
                                                    .font(.system(size: 12))
                                            } else {
                                                Label(model.quantization, systemImage: "cpu")
                                                    .font(.system(size: 12))
                                                
                                                Text("•")
                                                
                                                Label(model.formattedSize, systemImage: "externaldrive")
                                                    .font(.system(size: 12))
                                            }
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    if selectedModel?.id == model.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial)
                            )
                            .listRowSeparator(.hidden)
                            .disabled(model.isBuiltInAppleModel && !appleAvailability.isAvailable)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Select Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            await modelStore.refresh()
        }
    }
}

@MainActor
