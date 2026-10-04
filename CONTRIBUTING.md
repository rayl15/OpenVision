# Contributing to OpenVision

Thank you for your interest in contributing to OpenVision! This document provides guidelines and information for contributors.

## Code of Conduct

Be respectful, inclusive, and constructive. We welcome contributors of all skill levels.

## How to Contribute

### Reporting Bugs

1. Check [existing issues](https://github.com/rayl15/OpenVision/issues) first
2. Create a new issue with:
   - Clear, descriptive title
   - Steps to reproduce
   - Expected vs actual behavior
   - iOS version, device model
   - Relevant logs (filter by `[OpenClaw]`, `[Gemini]`, etc.)

### Suggesting Features

1. Check [existing discussions](https://github.com/rayl15/OpenVision/discussions) first
2. Open a new discussion describing:
   - The problem you're trying to solve
   - Your proposed solution
   - Alternative approaches considered

### Pull Requests

1. Fork the repository
2. Create a feature branch from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. Make your changes following our code style
4. Write/update tests as needed
5. Commit with clear messages:
   ```bash
   git commit -m "Add: Description of feature"
   git commit -m "Fix: Description of bug fix"
   git commit -m "Refactor: Description of refactoring"
   ```
6. Push and open a Pull Request

## Code Style

### Swift Guidelines

Follow [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/).

```swift
// GOOD: Clear, descriptive names
func startVoiceSession() async throws
func capturePhoto() -> Data?

// BAD: Abbreviated, unclear names
func startVS() async throws
func capPh() -> Data?
```

### Architecture Patterns

See [docs/architecture.md](docs/architecture.md) for the full map — layout, MVVM, the
`AIBackend` seam, and step-by-step guides for adding a backend or a native tool.

- **MVVM**: Views render and forward interactions; ViewModels (`@MainActor ObservableObject`) orchestrate
- **@MainActor**: Use for all UI-related code and managers
- **Singleton pattern**: For shared managers (SettingsManager, GlassesManager)
- **Protocol-oriented**: New backends conform to `AIBackend`; new tools to `NativeTool`
- **Async/await**: Prefer over completion handlers
- **Tests**: Pure logic (date math, routing, parsing) belongs in testable enums/functions with unit tests in `OpenVisionTests`

```swift
// GOOD: @MainActor isolation
@MainActor
final class MyService: ObservableObject {
    @Published var state: ServiceState = .idle

    func performAction() async throws {
        // Implementation
    }
}

// GOOD: Protocol for testability
protocol CameraServiceProtocol {
    func capturePhoto() async throws -> Data
}
```

### File Organization

```swift
// MARK: - Properties

@Published var isActive = false
private var webSocket: URLSessionWebSocketTask?

// MARK: - Initialization

init() {
    // Setup
}

// MARK: - Public Methods

func start() async throws {
    // Implementation
}

// MARK: - Private Methods

private func setupConnection() {
    // Implementation
}
```

### Documentation

Add documentation to public APIs:

```swift
/// Starts a voice conversation session.
///
/// This method connects to the configured AI backend and begins
/// listening for voice input.
///
/// - Throws: `AIBackendError.notConfigured` if no backend is configured
/// - Throws: `AIBackendError.connectionFailed` if connection fails
func startSession() async throws {
    // Implementation
}
```

### Error Handling

Use typed errors with clear cases:

```swift
enum AIBackendError: LocalizedError {
    case notConfigured
    case connectionFailed(Error)
    case authenticationFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AI backend is not configured"
        case .connectionFailed(let error):
            return "Connection failed: \(error.localizedDescription)"
        case .authenticationFailed:
            return "Authentication failed"
        case .timeout:
            return "Connection timed out"
        }
    }
}
```

## Testing

### Running Tests

```bash
# In Xcode
Cmd+U

# Or via command line
xcodebuild test -scheme OpenVision -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Writing Tests

- Place tests in `Tests/` directory
- Mirror the source file structure
- Use mocks for external dependencies

```swift
final class OpenClawServiceTests: XCTestCase {
    var sut: OpenClawService!
    var mockWebSocket: MockWebSocket!

    override func setUp() {
        super.setUp()
        mockWebSocket = MockWebSocket()
        sut = OpenClawService(webSocket: mockWebSocket)
    }

    func testConnectSendsAuthMessage() async throws {
        // Given
        let expectation = expectation(description: "Auth message sent")

        // When
        try await sut.connect()

        // Then
        XCTAssertTrue(mockWebSocket.sentMessages.contains { $0.contains("auth") })
    }
}
```

### Test Coverage

Aim for coverage of:
- Public API methods
- Error handling paths
- Edge cases (empty data, network failures)

## Project Structure

```
OpenVision/
├── App/                 # App entry point
├── Config/              # Configuration files
├── Models/              # Data models
├── Services/            # Business logic
│   ├── AIBackend/       # AI protocol & factory
│   ├── OpenClaw/        # OpenClaw WebSocket client
│   ├── GeminiLive/      # Gemini Live client
│   ├── Voice/           # Speech recognition
│   ├── Audio/           # Audio capture/playback
│   ├── Camera/          # Camera services
│   └── TTS/             # Text-to-speech
├── Managers/            # Singleton managers
├── Views/               # SwiftUI views
│   ├── VoiceAgent/      # Voice conversation UI
│   ├── History/         # Conversation history
│   ├── Settings/        # Settings panels
│   └── Components/      # Reusable UI components
└── Tests/               # Unit tests
```

## Commit Messages

Use conventional commit format:

```
Type: Short description (max 72 chars)

Optional longer description explaining the why and how.

Closes #123
```

Types:
- `Add`: New feature
- `Fix`: Bug fix
- `Refactor`: Code restructuring
- `Docs`: Documentation only
- `Test`: Adding/updating tests
- `Chore`: Maintenance tasks

## Pull Request Process

1. **Title**: Clear, descriptive title
2. **Description**: Explain what and why
3. **Testing**: Describe how you tested
4. **Screenshots**: Include for UI changes
5. **Breaking changes**: Call out any breaking changes

### PR Checklist

- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Comments added for complex logic
- [ ] Documentation updated if needed
- [ ] Tests added/updated
- [ ] No compiler warnings introduced
- [ ] CI is green

### Continuous integration

Every pull request is compiled by GitHub Actions (`.github/workflows/ci.yml`): the app and its
test target are built for a generic iOS device with code signing off, on a free macOS runner.
`main` requires that check to pass before a PR can merge, and that applies to maintainers too.

The workflow copies `Config.xcconfig.example` and `OpenVision/Config/Config.swift.example` into
place, so no secrets are needed to compile. If CI fails on your PR, open the job's log; the
`.xcactivitylog` files are attached as an artifact when the build step fails.

## Release Process

Releases are cut by a maintainer. Version numbers follow [Semantic Versioning](https://semver.org/):
a new backend or feature bumps the minor version, fixes alone bump the patch version.

1. Open a release branch from `main` (for example `release/2.15.0`).
2. Update `CHANGELOG.md`: move everything merged since the last release under a new
   `## [x.y.z] - YYYY-MM-DD` heading, grouped as Added / Changed / Fixed, with the PR number
   on each line.
3. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, run `xcodegen generate`,
   and commit as `Bump version to x.y.z (build N)`.
4. Open a pull request. `main` is protected, so the release commits go through CI like any
   other change; direct pushes to `main` are rejected.
5. After the merge, tag the merge commit and publish the release with narrative notes and a
   compare link:

   ```bash
   git tag -a vx.y.z -m "OpenVision x.y.z"
   git push origin vx.y.z
   gh release create vx.y.z --title "OpenVision x.y.z" --notes-file notes.md
   ```

The app is distributed as source; there is no App Store or TestFlight step in this repository.

## Questions?

- Open a [Discussion](https://github.com/rayl15/OpenVision/discussions)
- Check existing issues and PRs
- Read `CLAUDE.md` for technical context

---

Thank you for contributing to OpenVision! Your efforts help make AI assistants accessible to everyone.
