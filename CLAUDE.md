# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

**Matrix Dart SDK** is a comprehensive client SDK for the Matrix protocol written in pure Dart. It handles synchronization, room management, message events, VoIP, end-to-end encryption (E2EE), and database persistence. The SDK supports web, native (IO), and Flutter platforms.

### Key Components

- **Client** (`lib/src/client.dart`): Main entry point — manages login, sync, room lifecycle, and server communication
- **Room** (`lib/src/room.dart`): Represents a Matrix room with event history, members, and state
- **Event** (`lib/src/event.dart`): Represents individual Matrix events (messages, state changes, etc.)
- **Timeline** (`lib/src/timeline.dart`): Manages paginated message history for a room
- **Encryption** (`lib/encryption.dart`): E2EE support via vodozemac (Rust bindings)
- **Database** (`lib/src/database/`): Persistent storage using SQFlite or SQLite with encryption support
- **Matrix API Lite** (`lib/matrix_api_lite.dart`): Low-level HTTP bindings to Matrix Client-Server API
- **VoIP** (`lib/src/voip/`): Call session management with WebRTC support (mesh and LiveKit backends)
- **MSC Extensions** (`lib/msc_extensions/`): Matrix Spec Change (MSC) proposals (polls, widgets, OIDC, etc.)

## Development Commands

### Setup & Dependencies

```bash
dart pub get              # Install dependencies
pub global activate coverage  # For coverage reporting (CI does this)
```

### Code Quality

```bash
dart format lib test      # Format code (required for CI)
dart analyze              # Run static analysis with configured lints (includes famedly_dart_lints)
import_sorter --set-exit-if-changed .  # Sort imports (enforced by CI)
```

### Testing

```bash
# Run all tests with concurrency (default: number of CPU cores)
dart test --concurrency=$(getconf _NPROCESSORS_ONLN) test

# Run specific test file
dart test test/client_test.dart

# Skip E2EE/OLM tests (which require setup)
dart test --concurrency=$(getconf _NPROCESSORS_ONLN) test -x olm

# Run only OLM-specific tests (requires prior E2EE setup)
dart test --concurrency=$(getconf _NPROCESSORS_ONLN) test -t olm

# Generate coverage report (also cleans up generated files)
./scripts/test.sh

# Web platform test (Chrome required)
dart test test/box_test.dart --platform chrome

# E2EE integration tests (runs local homeserver — Synapse/Dendrite/Conduit)
# See scripts/integration-*.sh for details
export HOMESERVER_IMPLEMENTATION=synapse  # or dendrite/conduit
scripts/integration-server-${HOMESERVER_IMPLEMENTATION}.sh 2>&1 > /dev/null &
source scripts/integration-create-environment-variables.sh
scripts/integration-prepare-homeserver.sh
dart pub get
scripts/prepare_vodozemac.sh
dart test test_driver/matrixsdk_test.dart -p vm
```

### CI Workflow

The repository uses GitHub Actions (`.github/workflows/integrate.yml`):
- **Dart checks**: Formatting, analysis, linting via `famedly/frontend-ci-templates` shared workflow
- **E2EE tests**: Run against Synapse, Dendrite, and Conduit homeservers (optional fail-fast)
- **Coverage**: Two runs — with OLM and without — merged for total coverage reporting
- **Web compatibility**: Ensures SDK compiles to JavaScript via `webdev`
- **Database web tests**: Chrome-based tests for SQFlite web support

Tagging with `v*.*.*.` triggers automated publishing to pub.dev.

## Architecture Patterns

### Reactive Streams

The SDK extensively uses Dart's `Stream` and `StreamController` for reactive updates:
- **`onUpdate`**: Fired when room or event data changes
- **`onInsert`**: Fired when new events arrive
- **`onRemove`**: Fired on event deletion
- **`syncStream`**: Emits sync status updates and connection state

Example: Timeline pagination triggers `onUpdate` callbacks; room member changes emit events on `updateNotifier`.

### Event Model

**Event** is the base class; **MatrixEvent** (from API lite) provides raw protocol data. SDK Events wrap protocol data with:
- Decryption state (encrypted, decrypted, failed)
- Local caching (file downloads)
- UI state (sending status, read receipts)

Events are typically stored in rooms; timeline provides paginated access.

### Database & Caching

- **SQFlite/SQLite**: Persistent storage across sessions
- **In-memory caches**: `CachedStreamController` for room/event data to avoid re-fetching
- **Encryption**: SQFlite supports encrypted databases via `sqflite_encryption_helper`
- **Web support**: BoxCollection uses IndexedDB on web platforms

### Client Lifecycle

1. **Create**: Instantiate `Client` with optional database
2. **Check homeserver**: Validate server via `checkHomeserver(uri)`
3. **Login**: Use password, OIDC, SSO, or device token flows
4. **Sync**: Start recurring sync via `client.sync()` or `client.onSyncStream()`
5. **Access rooms**: Iterate `client.rooms` or lookup by ID
6. **Listen for events**: Subscribe to `room.onUpdate` or timeline streams
7. **Logout**: Call `client.logout()` to clean up

### E2EE Flow

When E2EE is enabled (via `Client(..., encryption: encryption)` with vodozemac):
1. Client manages device keys and uploads them to the server
2. Outgoing messages are encrypted before sending
3. Incoming encrypted events are queued and decrypted asynchronously
4. Key verification and device trust are managed via the encryption module

### File Encryption with Isolate Offloading

Large file encryption (AES-CTR) can be offloaded to background Isolates when using `NativeImplementationsIsolate`. This prevents ANR (Application Not Responding) errors when encrypting large video/media files on Flutter apps.

**Setup in Flutter app:**
```dart
import 'package:flutter/foundation.dart' show compute;
import 'package:matrix/matrix.dart';

final client = Client(
  'MyApp',
  nativeImplementations: NativeImplementationsIsolate(compute),
  // ... other config
);
```

The SDK automatically uses the provided implementation during file uploads. File and thumbnail uploads are parallelized using `Future.wait()`, reducing total upload time by 30-50%. For non-Flutter or non-isolate environments, the `NativeImplementations.dummy` default is used (inline encryption, no offloading).

**API Compatibility**: The `MatrixFile.encrypt()` method accepts an optional `nativeImplementations` parameter with default value `NativeImplementations.dummy`, ensuring backward compatibility with existing code.

## Code Style & Conventions

Per CONTRIBUTING.md and famedly_dart_lints:

- **File/dir names**: `snake_case`
- **Imports**: Sorted and formatted via `import_sorter` and `dart format`
- **Dartdoc**: All public classes, methods, and attributes must have documentation comments
- **Classes over functions**: Use classes for widget-like code, not functions
- **Avoid mixing paradigms**: Don't mix imperative state mutations (void returns) with functional programming
- **Extensions**: Use Dart extensions to extend class functionality rather than wrapper classes
- **No hardcoded strings**: Localize all user-facing text
- **Configuration**: Use analysis_options.yaml for linting rules; some rules are disabled (see non_constant_identifier_names, sort_pub_dependencies) due to legacy code

## Common Workflows

### Adding a New API Endpoint

1. Define the request/response models in `lib/matrix_api_lite/...` (generated from spec)
2. Add the HTTP method to `MatrixApi` in `lib/matrix_api_lite/matrix_api_lite.dart`
3. If it affects Client behavior, add a wrapper method to `lib/src/client.dart`
4. Write tests in `test/` mirroring the structure
5. Document with dartdoc comments

### Handling Encrypted Events

1. Incoming encrypted events are automatically queued in `_EventPendingDecryption`
2. Decryption happens asynchronously; events emit updates via `onUpdate` when decrypted
3. Failed decryptions remain in the timeline with `bodyIsPlaintext` flag set
4. Use `event.content['body']` for plaintext fallback

### Extending with MSC Features

MSC extensions are in `lib/msc_extensions/`. They typically:
- Export new model classes (e.g., `PollEventContent`)
- Add extension methods to `Room` or `Client` (e.g., `room.createPoll()`)
- Add utilities (e.g., `poll_room_extension.dart`)

To use: `import 'package:matrix/msc_extensions/msc_3381_polls/poll_event_extension.dart'`

## Notable Dependencies

- **vodozemac**: Rust-based E2EE (requires native binary or flutter_vodozemac)
- **SQFlite/SQLite**: Database with ForeignKey/encryption support
- **http**: HTTP client with timeout configuration
- **canonical_json**: Spec-compliant JSON encoding (used for signatures)
- **webrtc_interface**: Abstraction over native WebRTC implementations
- **markdown**: Event body parsing (with LaTeX support behind flag)

## Testing Patterns

- **FakeMatrixApi**: Mocks the entire HTTP layer for offline testing
- **FakeClient**: Pre-configured client for testing (see `test/fake_client.dart`)
- **FakeDatabase**: In-memory database mock
- **Test isolation**: Each test should set up its own client/database to avoid state leakage

## Debugging Tips

- Set environment variable `HOMESERVER` and user credentials for integration tests
- Use `--define=KEY=VALUE` flags for compile-time constants in tests
- Check `client.isLogged` and `client.rooms` state before assertions
- OLM tests require vodozemac setup; skip with `-x olm` if unavailable
- Coverage reports are in `coverage_dir/` after `./scripts/test.sh`
