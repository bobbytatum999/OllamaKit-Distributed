import SwiftUI
import SwiftData
import OllamaCore
import AVFoundation
import Speech
import PhotosUI

struct ModelComparisonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var primaryModel: ModelSnapshot?
    @StateObject private var modelStore = ModelStorage.shared
    @State private var selectedModel2: ModelSnapshot?
    @State private var compareInput = ""
    @State private var response1 = ""
    @State private var response2 = ""
    @State private var isRunning1 = false
    @State private var isRunning2 = false
    @State private var errorMessage: String?

    private var availableModels: [ModelSnapshot] {
        BuiltInModelCatalog.selectionModels(downloadedModels: modelStore.selectionSnapshots)
    }

    var body: some View {
        VStack(spacing: 16) {
            if availableModels.count < 2 {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text("Need at least 2 models")
                        .font(.headline)
                    Text("Download at least 2 models to use comparison mode")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        // Model selectors
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Model 1")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Menu {
                                    ForEach(availableModels.filter { $0.id != selectedModel2?.id }) { model in
                                        Button(model.displayName) {
                                            primaryModel = model
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(primaryModel?.displayName ?? "Select")
                                        Spacer()
                                        Image(systemName: "chevron.down")
                                    }
                                    .padding(10)
                                    .background(Capsule().fill(.ultraThinMaterial))
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Model 2")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Menu {
                                    ForEach(availableModels.filter { $0.id != primaryModel?.id }) { model in
                                        Button(model.displayName) {
                                            selectedModel2 = model
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(selectedModel2?.displayName ?? "Select")
                                        Spacer()
                                        Image(systemName: "chevron.down")
                                    }
                                    .padding(10)
                                    .background(Capsule().fill(.ultraThinMaterial))
                                }
                            }
                        }

                        // Input
                        TextField("Enter a prompt to compare...", text: $compareInput, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .lineLimit(3...6)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial)
                            )

                        Button {
                            runComparison()
                        } label: {
                            Label(
                                (isRunning1 || isRunning2) ? "Running..." : "Compare",
                                systemImage: "rectangle.split.2x1"
                            )
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill((primaryModel != nil && selectedModel2 != nil && !compareInput.isEmpty && !isRunning1 && !isRunning2) ? Color(hex: "8B5CF6") : Color.gray)
                            )
                        }
                        .disabled(primaryModel == nil || selectedModel2 == nil || compareInput.isEmpty || isRunning1 || isRunning2)

                        // Results
                        if !response1.isEmpty || !response2.isEmpty || isRunning1 || isRunning2 {
                            HStack(alignment: .top, spacing: 12) {
                                // Model 1 response
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(primaryModel?.displayName ?? "Model 1")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                        if isRunning1 {
                                            ProgressView()
                                                .scaleEffect(0.7)
                                        }
                                    }
                                    ScrollView {
                                        Text(response1.isEmpty ? "..." : response1)
                                            .font(.system(size: 14))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(minHeight: 80)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.gray.opacity(0.08))
                                    )
                                }

                                // Model 2 response
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(selectedModel2?.displayName ?? "Model 2")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                        if isRunning2 {
                                            ProgressView()
                                                .scaleEffect(0.7)
                                        }
                                    }
                                    ScrollView {
                                        Text(response2.isEmpty ? "..." : response2)
                                            .font(.system(size: 14))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(minHeight: 80)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.gray.opacity(0.08))
                                    )
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Compare Models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func runComparison() {
        guard let model1 = primaryModel, let model2 = selectedModel2 else { return }
        let prompt = compareInput

        // Run model 1
        isRunning1 = true
        response1 = ""
        Task {
            do {
                let actualParameters = await MainActor.run {
                    ModelParameters.appDefault
                }
                let gpuLayers = await MainActor.run {
                    AppSettings.shared.gpuLayers
                }
                try await ModelRunner.shared.loadModel(
                    catalogId: model1.catalogId,
                    contextLength: model1.runtimeContextLength,
                    gpuLayers: gpuLayers
                )
                let result = try await ModelRunner.shared.generate(
                    prompt: "",
                    systemPrompt: nil,
                    conversationTurns: [ConversationTurn(role: "user", content: prompt)],
                    parameters: actualParameters
                ) { _ in }
                await MainActor.run {
                    response1 = result.text
                    isRunning1 = false
                }
            } catch {
                await MainActor.run {
                    response1 = "Error: \(error.localizedDescription)"
                    isRunning1 = false
                }
            }
        }

        // Run model 2
        isRunning2 = true
        response2 = ""
        Task {
            do {
                let actualParameters = await MainActor.run {
                    ModelParameters.appDefault
                }
                let gpuLayers = await MainActor.run {
                    AppSettings.shared.gpuLayers
                }
                try await ModelRunner.shared.loadModel(
                    catalogId: model2.catalogId,
                    contextLength: model2.runtimeContextLength,
                    gpuLayers: gpuLayers
                )
                let result = try await ModelRunner.shared.generate(
                    prompt: "",
                    systemPrompt: nil,
                    conversationTurns: [ConversationTurn(role: "user", content: prompt)],
                    parameters: actualParameters
                ) { _ in }
                await MainActor.run {
                    response2 = result.text
                    isRunning2 = false
                }
            } catch {
                await MainActor.run {
                    response2 = "Error: \(error.localizedDescription)"
                    isRunning2 = false
                }
            }
        }
    }
}
