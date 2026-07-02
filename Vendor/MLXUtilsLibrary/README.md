# MLXUtilsLibrary

Utilities for easing the development of machine learning inference libraries and applications on iOS and macOS using the MLX framework.

## Requirements

- iOS 18.0+
- macOS 15.0+

## Installation

Add MLXUtilsLibrary to your project using Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/MLXUtilsLibrary.git", from: "0.0.1")
]
```

Then add it to your target dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: ["MLXUtilsLibrary"]
)
```

## Usage

### Loading NumPy Files

```swift
import MLXUtilsLibrary
import MLX

// Load a single .npy file
if let arrays = NpyzReader.read(fileFromPath: npyFileURL) {
    let array = arrays["npy"]  // MLXArray
    print(array?.shape)
}

// Load a .npz archive (containing multiple arrays)
if let arrays = NpyzReader.read(fileFromPath: npzFileURL) {
    for (name, array) in arrays {
        print("\(name): \(array.shape)")
    }
}

// Load from Data
let data = try Data(contentsOf: fileURL)
let arrays = NpyzReader.read(data: data, isPacked: true)
```

## Features

### NumPy File Support
- **NpyzReader**: Load NumPy `.npy` and `.npz` files directly into MLX arrays
- Support for all common data types (bool, int8-64, uint8-64, float32/64)
- Handles both little-endian and big-endian formats
- Based on [swift-npy](https://github.com/qoncept/swift-npy)

### Development Tools
- **BenchmarkTimer**: Performance measurement utilities for profiling ML operations
- **MLXArray Extensions**: Enhanced debug printing for MLX arrays
- **Logging Utilities**: Convenient logging helpers

## License

See [LICENSE](LICENSE) file for details.

## Acknowledgments

- NumPy file reading based on [swift-npy](https://github.com/qoncept/swift-npy)
- Built for use with [MLX Swift](https://github.com/ml-explore/mlx-swift)