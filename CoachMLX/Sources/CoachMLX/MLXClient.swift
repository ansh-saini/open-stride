import CoachKit
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

public enum OnDeviceModel: String, CaseIterable, Codable, Identifiable {
    case gemma4B = "mlx-community/gemma-3-text-4b-it-4bit"
    case gemma1B = "mlx-community/gemma-3-1b-it-qat-4bit"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .gemma4B: "Gemma 3 4B"
        case .gemma1B: "Gemma 3 1B"
        }
    }

    public var sizeLabel: String {
        switch self {
        case .gemma4B: "2.6 GB download. Better coaching. Best on iPhones with 8 GB RAM."
        case .gemma1B: "0.8 GB download. Faster, weaker judgment."
        }
    }

    var configuration: ModelConfiguration {
        ModelConfiguration(id: rawValue, extraEOSTokens: ["<end_of_turn>"])
    }
}

/// Runs Gemma on the iPhone GPU with MLX. Weights download once from Hugging Face, then everything is offline.
public final class MLXClient: LLMClient, @unchecked Sendable {
    public let model: OnDeviceModel
    /// Prompt tokens processed per step. Smaller means a lower memory peak (Gemma's 262k vocab makes logits large).
    public var prefillStep: Int
    /// Quantize the KV cache to this many bits; nil keeps full precision.
    public var kvBits: Int?
    private let loader: Loader

    public init(model: OnDeviceModel, prefillStep: Int = 64, kvBits: Int? = nil, onProgress: @escaping @Sendable (Double) -> Void) {
        self.model = model
        self.prefillStep = prefillStep
        self.kvBits = kvBits
        loader = Loader(configuration: model.configuration, onProgress: onProgress)
    }

    public var name: String { "\(model.label) (on-device)" }

    public func complete(system: String, user: String, schema: [String: any Sendable]) async throws -> String {
        let container = try await loader.container()
        let session = ChatSession(
            container,
            instructions: system,
            generateParameters: GenerateParameters(
                maxTokens: 400, kvBits: kvBits, temperature: 0.2, prefill: PrefillParameters(stepSize: prefillStep)
            )
        )
        return try await session.respond(to: user)
    }

    public func preload() async throws { _ = try await loader.container() }

    /// Highest MLX memory use since launch, in bytes.
    public static var peakMemory: Int { MLX.Memory.peakMemory }

    /// Physical RAM of this device.
    public static var deviceMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    actor Loader {
        let configuration: ModelConfiguration
        let onProgress: @Sendable (Double) -> Void
        private var loaded: ModelContainer?

        init(configuration: ModelConfiguration, onProgress: @escaping @Sendable (Double) -> Void) {
            self.configuration = configuration
            self.onProgress = onProgress
        }

        func container() async throws -> ModelContainer {
            if let loaded { return loaded }
            // Keep the GPU buffer cache small; the phone needs the memory for weights.
            MLX.Memory.cacheLimit = 32 * 1024 * 1024
            let progress = onProgress
            let c = try await #huggingFaceLoadModelContainer(configuration: configuration) { p in
                progress(p.fractionCompleted)
            }
            loaded = c
            return c
        }
    }
}
