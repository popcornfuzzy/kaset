# Testing Guide

This document covers testing strategies, commands, and best practices for Kaset.

## Test Commands

### Unit Tests

```bash
swift test
```

### Build Only

```bash
swift build
```

### Package App

```bash
Scripts/build-app.sh
```

### Dev Loop (Build + Run)

```bash
Scripts/compile_and_run.sh
```

### Lint & Format

```bash
swiftlint --strict && swiftformat .
```

## Test Structure

```
Tests/KasetTests/
├── Helpers/
│   ├── MockURLProtocol.swift    # Network mocking
│   ├── MockYTMusicClient.swift  # API client mock
│   └── TestFixtures.swift       # Fixture loading utilities
├── SwiftTestingHelpers/
│   └── Tags.swift               # Custom test tags (.api, .parser, etc.)
├── Fixtures/
│   ├── home_response.json       # Sample API responses
│   ├── search_response.json
│   └── playlist_detail.json
├── *Tests.swift                 # Unit test files (Swift Testing)
└── MusicIntentIntegrationTests.swift  # AI integration tests
```

## Unit Test Requirements

New code in `Sources/Kaset/` (Services, Models, ViewModels, Utilities) must include unit tests.

### Creating a Test File

1. Create test file in `Tests/KasetTests/` matching the source file name
   - Example: `YTMusicClient.swift` → `YTMusicClientTests.swift`
2. Add the test file to the Xcode project
3. Run tests to verify

### Test File Template (Swift Testing)

> **Note:** This project uses Swift Testing (not XCTest). See [ADR-0006](adr/0006-swift-testing-migration.md) for migration details.

```swift
import Testing
@testable import Kaset

@Suite("MyService", .serialized, .tags(.service))
@MainActor
struct MyServiceTests {
    let sut: MyService
    let mockClient: MockYTMusicClient

    init() {
        mockClient = MockYTMusicClient()
        sut = MyService(client: mockClient)
    }

    @Test("Does something correctly")
    func doesSomething() async throws {
        // Arrange
        mockClient.homeResponse = HomeResponse(sections: [], continuationToken: nil)

        // Act
        let result = try await sut.doSomething()

        // Assert
        #expect(result != nil)
    }
}
```

### Key Swift Testing Patterns

| XCTest | Swift Testing |
|--------|---------------|
| `import XCTest` | `import Testing` |
| `class ... : XCTestCase` | `@Suite struct ...` |
| `func testFoo()` | `@Test func foo()` |
| `XCTAssertEqual(a, b)` | `#expect(a == b)` |
| `XCTAssertTrue(x)` | `#expect(x)` |
| `XCTAssertNil(x)` | `#expect(x == nil)` |
| `XCTAssertThrowsError` | `#expect(throws:)` |
| `setUp()` / `tearDown()` | `init()` (ARC handles cleanup) |

### @MainActor Test Suites

For tests of `@MainActor` classes (most services), use `.serialized`:

```swift
@Suite("PlayerService", .serialized, .tags(.service))
@MainActor
struct PlayerServiceTests {
    let sut: PlayerService

    init() {
        sut = PlayerService()
    }

    @Test("Initial state is idle")
    func initialStateIsIdle() {
        #expect(sut.isPlaying == false)
    }
}
```

**Why `.serialized`?** `@MainActor` tests must run serially to avoid race conditions. Swift Testing runs tests in parallel by default.

**`.serialized` only orders tests *within* a suite.** Suites still run concurrently with each other, so two suites that touch the same `@MainActor` singleton still interleave at `await` points — one suite's `init()`/setup can clear state in the middle of another's test. That is why CI runs the whole bundle with `--no-parallel` (see [CI](#ci-configuration)): the suite is written for serial execution, and this makes the run deterministic instead of depending on which suites happen to overlap.

Keep tests independent of that too, when you can: prefer asserting on objects the test owns over app-wide singletons, and wait for the condition you assert on rather than sleeping a fixed amount.

### Waiting for async work

`Task.sleep(for: .milliseconds(200))` encodes an assumption about how fast the machine is. When the thing being tested is asynchronous end to end — a spawned task, a coalescing burst, a retry loop — wait for an event the code emits instead:

```swift
await waitUntil("the rating request to be sent") { self.mockClient.rateSongCalled }
```

`waitUntil` (`Tests/KasetTests/SwiftTestingHelpers/AsyncTestWait.swift`) polls the condition on the main actor, yields between checks, and records an issue if the timeout passes.

This matters most where a test has to *interleave* two async actions — a coalescing burst is defined by the second intent arriving while the first is still waiting out its debounce. Sleeping a fixed amount there does not guarantee the first task has even started, so the burst is not coalesced and the test fails on a slow machine while passing locally. Rendezvous on an observable event instead (the optimistic cache write, or the request reaching the mock client):

```swift
let first = Task { await manager.like(song, accountID: accountID, client: mockClient, debounce: window) }
await waitUntil("the like to be cached") { manager.status(for: song.videoId, accountID: nil) == .like }
let second = Task { await manager.unlike(song, accountID: accountID, client: mockClient, debounce: window) }
```

A sleep is still the right tool for asserting that something *did not* happen — `#expect(self.mockClient.rateSongCalled == false)` has no event to wait for. Say so in a comment, so it is not mistaken for a rendezvous.

### Test Tags

Apply tags to categorize tests for filtering:

```swift
@Suite("HomeViewModel", .tags(.viewModel), .timeLimit(.minutes(1)))
```

Available tags: `.api`, `.parser`, `.viewModel`, `.service`, `.model`, `.slow`, `.integration`

**Run by tag:**

`swift test --filter`/`--skip` match against test IDs (target, suite and test names), **not** tags, so `swift test --skip integration` selects nothing. Use the suite names in the pattern, and the `--test-tag` / `--skip-test-tag` flags when driving the suite through `xcodebuild`:

```bash
# SwiftPM: select / exclude by name
swift test --filter "CanvasVideoViewTests|MusicIntentIntegrationTests"
swift test --skip "KasetUITests|MusicIntentIntegrationTests"

# xcodebuild: select / exclude by tag
xcodebuild test -scheme Kaset -only-testing:KasetTests --test-iterations 1 -skip-test-tag .slow
```

### Time Limits

Add `.timeLimit()` to async tests to prevent hangs:

```swift
@Suite("SearchViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
```

## Environment Isolation

### Using MockURLProtocol

For network testing without real API calls:

```swift
// In test setup
let config = URLSessionConfiguration.ephemeral
config.protocolClasses = [MockURLProtocol.self]
let session = URLSession(configuration: config)

// Set response handler
MockURLProtocol.requestHandler = { request in
    let json = """
    {"id": "123", "data": [...]}
    """
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!
    return (response, json.data(using: .utf8)!)
}
```

## Test Categories

### Service Tests

Test business logic in isolation:

```swift
@Test("Login state transitions correctly")
func authServiceLoginState() async {
    let authService = AuthService()

    authService.startLogin()

    #expect(authService.state == .loggingIn)
}
```

### Model Tests

Test parsing and computed properties:

```swift
@Test("Song parses duration from seconds field")
func songDurationParsing() throws {
    let data: [String: Any] = [
        "videoId": "abc123",
        "title": "Test Song",
        "duration_seconds": 185.0,
    ]

    let song = try #require(Song(from: data))

    #expect(song.videoId == "abc123")
    #expect(song.duration == 185.0)
    #expect(song.durationDisplay == "3:05")
}
```

### ViewModel Tests

Test state management and loading:

```swift
@Test("Home loads sections from API")
func homeViewModelLoading() async throws {
    let mockClient = MockYTMusicClient()
    mockClient.homeResponse = HomeResponse(sections: [makeSection()], continuationToken: nil)
    let viewModel = HomeViewModel(client: mockClient)

    await viewModel.load()

    #expect(!viewModel.isLoading)
    #expect(!viewModel.sections.isEmpty)
}
```

### Parser Tests

Test API response parsing with mock data:

```swift
@Test("Parses home response with sections")
func parseHomeResponse() {
    let data = makeHomeResponseData(sectionCount: 3)

    let (sections, token) = HomeResponseParser.parse(data)

    #expect(sections.count == 3)
}
```

### Parameterized Tests

Test multiple inputs efficiently:

```swift
@Test("Duration formatting", arguments: [
    (0.0, "0:00"),
    (65.0, "1:05"),
    (3661.0, "1:01:01"),
])
func durationFormatting(seconds: Double, expected: String) {
    let song = makeSong(duration: seconds)
    #expect(song.durationDisplay == expected)
}
```

## Mocking Guidelines

### MockYTMusicClient

The project includes a ready-to-use mock client:

```swift
// Tests/KasetTests/Helpers/MockYTMusicClient.swift
final class MockYTMusicClient: YTMusicClientProtocol, @unchecked Sendable {
    var homeResponse: HomeResponse?
    var searchResponse: SearchResponse?
    var error: Error?

    func getHome() async throws -> HomeResponse {
        if let error { throw error }
        return homeResponse ?? HomeResponse(sections: [], continuationToken: nil)
    }
    // ... other methods
}
```

**Usage in tests**:
```swift
func testHomeViewModelLoading() async throws {
    let mockClient = MockYTMusicClient()
    mockClient.homeResponse = HomeResponse(sections: [...], continuationToken: nil)

    let viewModel = HomeViewModel(client: mockClient)
    await viewModel.load()

    XCTAssertFalse(viewModel.sections.isEmpty)
}
```

### MockURLProtocol

For lower-level network testing:

```swift
// Tests/KasetTests/Helpers/MockURLProtocol.swift
MockURLProtocol.requestHandler = { request in
    let data = TestFixtures.loadJSON("home_response")
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, ...)
    return (response, data)
}
```

### TestFixtures

Load JSON fixtures from the `Fixtures/` directory:

```swift
// Tests/KasetTests/Helpers/TestFixtures.swift
let data = TestFixtures.loadJSON("home_response")  // Loads home_response.json
let dict = TestFixtures.loadJSONDict("search_response")
```

## Accessibility Testing

### VoiceOver

Test with VoiceOver enabled:

1. Enable: System Settings → Accessibility → VoiceOver
2. Navigate app using keyboard (Tab, Cmd+arrows)
3. Verify all controls have labels

### Required Labels

All icon-only buttons must have accessibility labels:

```swift
Button {
    playerService.playPause()
} label: {
    Image(systemName: "play.fill")
}
.accessibilityLabel("Play")
```

## Integration Testing

### AI Integration Tests (Apple Intelligence)

The `MusicIntentIntegrationTests` suite validates LLM parsing of natural language commands into `MusicIntent` structs.

#### Requirements

- macOS 26+ with Apple Intelligence enabled
- Tests skip gracefully when AI is unavailable via `throw TestSkipped()`

#### Flakiness Mitigation

LLM outputs are inherently non-deterministic. These tests mitigate flakiness by:

1. **Retry logic**: Each test retries up to 3 times before failing (with 500ms delays)
2. **Relaxed matching**: Checks multiple fields (e.g., `mood` OR `query`) for expected content
3. **Case-insensitive**: All string comparisons are lowercased
4. **Fresh sessions**: Each attempt uses a new `LanguageModelSession` to avoid context drift
5. **Excluded from CI**: the unit-test jobs skip this suite by name (see [CI Configuration](#ci-configuration))

#### CI Configuration

Non-deterministic or environment-dependent tests never gate a pull request or a release. `.github/workflows/tests.yml` and `release.yml` run:

```bash
# Stable unit tests: serial execution, without the LLM suite
swift test -q --no-parallel --skip "KasetUITests|MusicIntentIntegrationTests"
```

The Apple Intelligence suite runs in the scheduled `macos_integration_tests` job (nightly and on `workflow_dispatch`), where a failure is a signal to investigate rather than a blocked merge:

```bash
swift test -q --no-parallel --filter "MusicIntentIntegrationTests"
```

Other environment-dependent suites to keep out of the merge gate:

| Suite | Depends on |
|-------|------------|
| `MusicIntentIntegrationTests` | Apple Intelligence; non-deterministic output |
| `CanvasVideoViewTests` | Real AVFoundation playback; the first item in a process can take many seconds to start on a busy or paravirtualized runner, so its readiness wait is generous |

#### What's Tested

| Category         | Test Count | Example Prompts                              |
| ---------------- | ---------- | -------------------------------------------- |
| Basic Actions    | 5          | "Play music", "Skip", "Pause", "Like this"   |
| Mood Queries     | 5          | "Play something chill", "Play upbeat music"  |
| Genre Queries    | 5          | "Play jazz", "Play rock", "Play electronic"  |
| Era Queries      | 4          | "Play 80s hits", "Play 90s top songs"        |
| Artist Queries   | 3          | "Play Beatles", "Play Taylor Swift"          |
| Activity Queries | 4          | "Music for studying", "Workout songs"        |
| Complex Queries  | 3          | "Chill jazz from the 80s", "Acoustic covers" |
| Queue Action     | 1          | "Add jazz to the queue"                      |
| **Total**        | **~30**    |                                              |

#### Run Commands

```bash
# Run ONLY integration tests (requires Apple Intelligence)
swift test --filter "MusicIntentIntegrationTests"

# Run the full unit suite the way CI does
swift test -q --no-parallel --skip "KasetUITests|MusicIntentIntegrationTests"
```

#### Test Characteristics

- **Tagged**: `.integration` and `.slow` for easy filtering
- **Auto-skip**: Uses `.enabled(if:)` to skip entire suite when AI unavailable
- **Parameterized**: Efficient coverage with Swift Testing's `arguments:`
- **Retry-enabled**: Up to 3 attempts per test to handle LLM non-determinism
- **Relaxed validation**: Checks multiple fields to accommodate LLM output variance

### Manual Test Checklist

Before releasing:

- [ ] Fresh login works (delete app data first)
- [ ] Home page loads with content
- [ ] Search returns results
- [ ] Playback starts on click
- [ ] Track changes work
- [ ] Background audio works (close window)
- [ ] Media keys work
- [ ] Re-opening window doesn't duplicate audio
- [ ] Sign out and re-login works

### Simulating Auth Expiry

To test auth recovery:

1. Open Safari → Develop → Show Web Inspector (for any WebView)
2. Storage → Cookies → Delete `__Secure-3PAPISID`
3. Trigger an API call → should show login sheet

## Debugging

### Console Logging

Use Xcode's Console to filter logs:

```
subsystem:Kaset category:player
subsystem:Kaset category:auth
```

### WebView Debugging

Enable Web Inspector for debug builds:

```swift
#if DEBUG
    webView.isInspectable = true
#endif
```

Right-click WebView → Inspect Element

## Continuous Integration

Four workflows, each with a single responsibility:

| Workflow | Trigger | Runs |
|----------|---------|------|
| `tests.yml` | push/PR to `main`, nightly | Unit + UI tests; integration suites nightly |
| `dev-build.yml` | push/PR touching Swift sources | Builds a dev DMG |
| `lint.yml` | push/PR to `main` | `swiftlint --strict`, `swiftformat` |
| `release.yml` | tag push `v*` | Gated build, draft GitHub release |
| `appcast.yml` | release published | Signs the DMG, commits `appcast.xml` |

### Unit Test Gate

`tests.yml` and `release.yml` run the same command, so a pull request and a release are gated
identically:

```bash
swift test -q --no-parallel --skip "KasetUITests|MusicIntentIntegrationTests|CanvasVideoViewTests"
```

The command is retried once. The suite is timing-sensitive, and a paravirtualized runner is slower
than a developer machine, so a single retry absorbs a residual flake instead of failing a release;
a real failure still fails both attempts. Do not treat the retry as licence to leave a suite with
fixed sleeps in the gate — wait for the condition instead (see [Waiting for async work](#waiting-for-async-work)).

`swift test` takes `--skip`/`--filter` patterns that match test IDs (target, suite, and test
names), **not** tags, which is why the suites above are named explicitly. Android-style tag
filtering (`--skip-test-tag`) only applies when driving the suite through `xcodebuild`.

### CI Job Layout

```yaml
jobs:
  macos_unit_tests:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v6

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_26.2.app/Contents/Developer

      - name: Run unit tests        # retried once, see above
        run: swift test -q --no-parallel --skip "KasetUITests|MusicIntentIntegrationTests|CanvasVideoViewTests"

  macos_integration_tests:          # nightly and on demand only
    if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
    steps:
      - run: swift test -q --no-parallel --filter "MusicIntentIntegrationTests"
```

Release mechanics are covered by
[adr/0019-release-pipeline-and-appcast-publication.md](adr/0019-release-pipeline-and-appcast-publication.md).
