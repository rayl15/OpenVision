//
//  Kokoro-tts-lib
//
import Foundation

/// Main configuration structure for the Kokoro TTS model.
///
/// This structure defines all hyperparameters and architectural settings needed
/// to initialize the TTS model components. The configuration includes:
/// - Decoder settings (iSTFT network parameters)
/// - BERT encoder settings (PLBERT configuration)
/// - Dimension and layer specifications
/// - Vocabulary mappings
///
/// Configuration is loaded from a JSON file bundled with the module.
struct KokoroConfig: Decodable {
  /// Shared configuration instance cached after first load
  nonisolated(unsafe) static var config: KokoroConfig?

  /// Configuration for the iSTFT (Inverse Short-Time Fourier Transform) decoder network.
  /// Defines the architecture of the decoder that converts mel-spectrograms to audio.
  /// Uses multiple upsampling stages with residual blocks for high-quality audio generation.
  struct IstftnetConfig: Decodable {
    /// Kernel sizes for each upsampling layer (controls smoothness of upsampling)
    let upsampleKernelSizes: [Int]
    
    /// Upsampling rates for each stage (determines output length multiplication)
    let upsampleRates: [Int]
    
    /// Hop size for iSTFT (spacing between consecutive STFT windows in samples)
    let genIstftHopSize: Int
    
    /// FFT size for iSTFT (number of frequency bins in the spectrogram)
    let genIstftNFFT: Int
    
    /// Dilation rates for residual blocks at each stage (controls receptive field)
    let resblockDilationSizes: [[Int]]
    
    /// Kernel sizes for residual blocks (temporal convolution sizes)
    let resblockKernelSizes: [Int]
    
    /// Number of channels in the first upsampling layer
    let upsampleInitialChannel: Int
    
    enum CodingKeys: String, CodingKey {
      case upsampleKernelSizes = "upsample_kernel_sizes"
      case upsampleRates = "upsample_rates"
      case genIstftHopSize = "gen_istft_hop_size"
      case genIstftNFFT = "gen_istft_n_fft"
      case resblockDilationSizes = "resblock_dilation_sizes"
      case resblockKernelSizes = "resblock_kernel_sizes"
      case upsampleInitialChannel = "upsample_initial_channel"
    }
  }
  
  /// Configuration for the PLBERT (Phoneme-Level BERT) encoder.
  /// Defines the architecture of the BERT-based encoder used to generate
  /// contextual embeddings from phoneme sequences.
  struct Plbert: Decodable {
    /// Size of hidden layer representations
    let hiddenSize: Int
    
    /// Number of attention heads in multi-head attention layers
    let numAttentionHeads: Int
    
    /// Size of the intermediate (feed-forward) layer
    let intermediateSize: Int
    
    /// Maximum sequence length supported (for position embeddings)
    let maxPositionEmbeddings: Int
    
    /// Number of transformer layers in the encoder
    let numHiddenLayers: Int
    
    /// Dropout probability for regularization (not used in inference)
    let dropout: Double
    
    enum CodingKeys: String, CodingKey {
      case hiddenSize = "hidden_size"
      case numAttentionHeads = "num_attention_heads"
      case intermediateSize = "intermediate_size"
      case maxPositionEmbeddings = "max_position_embeddings"
      case numHiddenLayers = "num_hidden_layers"
      case dropout = "dropout"
    }
  }
    
  /// iSTFT decoder network configuration
  let istftNet: IstftnetConfig
  
  /// Input dimension size (initial feature dimension)
  let dimIn: Int
  
  /// Dropout probability for training (not used in inference)
  let dropout: Double
  
  /// Hidden dimension size used throughout the model
  let hiddenDim: Int
  
  /// Maximum convolution dimension (caps feature map growth)
  let maxConvDim: Int
  
  /// Maximum duration in frames (for duration prediction bounds)
  let maxDur: Int
  
  /// Whether the model supports multiple speakers
  let multispeaker: Bool
  
  /// Number of layers in encoder/decoder stacks
  let nLayer: Int
  
  /// Number of mel-spectrogram frequency bins
  let nMels: Int
  
  /// Vocabulary size (number of unique phoneme tokens)
  let nToken: Int
  
  /// Dimension of style embeddings (for speaker/prosody conditioning)
  let styleDim: Int
  
  /// Kernel size for text encoder convolutions
  let textEncoderKernelSize: Int
  
  /// PLBERT encoder configuration
  let plbert: Plbert
  
  /// Vocabulary mapping from phoneme strings to token IDs
  let vocab: [String: Int]
  
  enum CodingKeys: String, CodingKey {
    case istftNet = "istftnet"
    case dimIn = "dim_in"
    case dropout = "dropout"
    case hiddenDim = "hidden_dim"
    case maxConvDim = "max_conv_dim"
    case maxDur = "max_dur"
    case multispeaker = "multispeaker"
    case nLayer = "n_layer"
    case nMels = "n_mels"
    case nToken = "n_token"
    case styleDim = "style_dim"
    case textEncoderKernelSize = "text_encoder_kernel_size"
    case plbert = "plbert"
    case vocab = "vocab"
  }
    
  /// Loads the configuration from the bundled config.json file.
  ///
  /// This method reads the configuration file from the module's Resources directory,
  /// parses it as JSON, and caches the result for future use.
  ///
  /// - Returns: Parsed KokoroConfig instance
  /// - Note: Uses forced unwrapping (try!) as configuration loading is critical
  ///         and should fail fast if the file is missing or malformed
  nonisolated static func loadConfig() -> KokoroConfig {
    // Locate config.json in the module bundle
    let fileURL = Bundle.module.url(forResource: "config", withExtension: "json", subdirectory: "Resources")!
    
    // Read file contents
    let configJSON = try! String(contentsOf: fileURL, encoding: .utf8)
    
    // Parse JSON and cache the result
    KokoroConfig.config = try! JSONDecoder().decode(KokoroConfig.self, from: configJSON.data(using: .utf8)!)
    
    return KokoroConfig.config!
  }
}
