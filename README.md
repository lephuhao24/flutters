# FVM GUI

A native macOS 14+ SwiftUI interface for the existing FVM CLI. Swift 6, Observation, actors, Foundation Process/Pipe, and XCTest. No third-party dependencies.

## Setup and run

1. Install Xcode supporting Swift 6. This project uses Xcode 27's `project.xcproj` format; verified with Xcode 27.2.
2. Use an existing [FVM](https://fvm.app/documentation/getting-started/installation) installation, or install it from Dependency Setup through Homebrew. JSON API compatibility is verified against **FVM 4.3.1**. Older releases without this API are rejected with instructions in Settings.
3. Open `fvm_gui.xcodeproj`, select the shared `fvm_gui` scheme, and run on My Mac.
4. If automatic discovery fails, open Settings (`⌘,`), choose the FVM executable, and select Validate & Refresh.

Automatic discovery supplements PATH with Apple Silicon/Intel Homebrew, Dart Pub (`~/.pub-cache/bin`), and system tools. A manually selected executable always takes precedence; an invalid override is not silently replaced. Shell profile files are not executed.

## Dependency setup

Launch checks existing FVM first; users with working installations go directly to the app. Missing dependencies show native setup states: checking, ready, missing Homebrew, missing FVM, installing, and failed. Settings and Setup share manual FVM/Homebrew executable selection. Paths persist in UserDefaults; an invalid FVM override must be corrected or cleared rather than silently installing a second copy.

Homebrew discovery validates `--version` and `--prefix`, checks PATH plus `/opt/homebrew/bin/brew` (Apple Silicon) and `/usr/local/bin/brew` (Intel), and accepts a custom executable. A custom prefix's `bin/fvm` is also checked when ordinary FVM detection fails.

When Homebrew is available and FVM is missing, **Install FVM** runs the selected Homebrew executable directly with `["install", "fvm"]` using the existing CLIExecutor. stdout/stderr stream into Setup and Activity; Cancel terminates the process group and keeps installation locked until cleanup finishes. Nonzero exits, launch/permission errors, and unsuccessful verification show actionable details. Successful installation is followed by full FVM executable/version/API detection before activating the SDK screens. Check Again is available after cancellation or manual installation. Homebrew operations started independently in Terminal are not coordinated with this app.

If Homebrew is missing, Setup displays the command from the [official Homebrew website](https://brew.sh/), a Copy Command button, and Open Homebrew Website. **The app never executes the Homebrew installation script.** Run it yourself in Terminal, review its prompts, complete the official post-install instructions, then check again. Consult [Homebrew's current platform requirements](https://docs.brew.sh/Installation), especially on older macOS/Intel systems.

## Build and test

```sh
xcodebuild -project fvm_gui.xcodeproj -scheme fvm_gui \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/fvm-gui-build CODE_SIGNING_ALLOWED=NO build

xcodebuild -project fvm_gui.xcodeproj -scheme fvm_gui \
  -destination 'platform=macOS' -derivedDataPath /tmp/fvm-gui-build \
  CODE_SIGNING_ALLOWED=NO test

xcodebuild -project fvm_gui.xcodeproj -scheme fvm_gui \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/fvm-gui-build CODE_SIGNING_ALLOWED=NO build
```

Unsigned build commands are for local verification. For distribution, configure your own bundle identifier and Developer ID signing team, archive with Hardened Runtime, sign the exported application, notarize using Apple's `notarytool`, and staple the ticket. Developer ID signing/notarization requires your account and is not included in source validation.

## Usage and behavior

- **Installed SDKs:** refresh installed versions, install an explicit version/channel, set global, or confirm removal. Global status resolves FVM's global cache symlink. Channel is shown only when known; a numeric version does not establish its channel.
- **Available Releases:** fetch FVM's release catalog, search versions, filter channels, and install. Installation shows actual CLI output in Activity with indeterminate progress, never estimated percentages.
- **Projects:** add a project directly or discover nested Flutter apps, packages, plugins, and Dart packages under folders selected by the user. YAML is parsed with Yams; scan depth is configurable, excluded folders and symlinks are skipped, and FVM versions may inherit from `.fvmrc` within each selected root. Discovery can be cancelled, imports deduplicate canonical paths, ignored paths and approved scan roots persist, and registered project metadata remains in UserDefaults. Read-only security-scoped bookmarks are stored for selected roots when available.
- **Change Version:** selects an installed SDK and runs `fvm use <version> --skip-pub-get` from that project. FVM may update `.fvmrc`, SDK links, `.gitignore`, or editor configuration. A local selection overrides inherited configuration. Run dependency resolution separately when needed.
- **Remove from List:** removes only GUI metadata. Removing an SDK deletes its FVM cache directory; the confirmation lists known registered users, but other projects may also depend on it.
- **Activity:** in-memory command/output/status history (100 operations, 200,000 characters per operation). stdout and stderr stream concurrently. Logs are not persisted; environment variables and raw `api context` responses are never logged.
- **Cancel:** terminates the operation's process group and drains pipes before releasing the modification lock. Partial SDK downloads/configuration edits are not rolled back. Refresh before retrying. Cancellation of a completed operation cannot undo it.

FVM owns all SDK management; the app never implements downloads or edits FVM configurations itself. Mutation commands are serialized across features. Exit status alone is insufficient: the service checks the installed/global/project state after a successful command. Queries time out; downloads remain cancellable without an artificial timeout.

## Permissions and architecture

This directly distributed developer tool intentionally **disables App Sandbox**, as explicitly selected for the MVP: FVM needs to modify its SDK cache and user-selected projects and run git/dart/flutter children. Hardened Runtime is enabled. The app runs with your account's permissions, never requests root privileges, and does not weaken system protections. Only select FVM and Homebrew executables you trust.

`AppContainer` supplies constructor-injected services. Main-actor observable ViewModels drive SwiftUI; actors isolate CLI/project work. `CLIExecuting`, `ExecutableLocating`, `FVMService`, and `ProjectServicing` are mockable. CLI arguments are arrays, not shell strings. The app does not run shell profiles or shell interpolation. UserDefaults stores executable preferences, registered project metadata, approved project scan roots/bookmarks, ignored canonical paths, and the last successful discovery timestamp; activity is session-only.

Tests use captured FVM JSON fixtures (see `FVMGUITests/Fixtures/README.md`) and clearly synthetic edge cases. Local process tests exercise concurrent pipes, Unicode, spaces, literal arguments, failures, cancellation, and timeout. Unit tests never download Flutter SDKs or modify your existing SDK cache.

## Compatibility and limits

- CLI flags and JSON were verified with local FVM 4.3.1. Schema changes produce actionable errors instead of guessing table output. See the [official JSON API documentation](https://github.com/leoafarias/fvm/blob/4.3.1/docs/pages/documentation/advanced/json-api.md).
- Network/proxy/permission errors surface in the UI; retry Refresh after fixing the underlying issue. FVM can print an error with exit code zero, so non-JSON responses are rejected.
- Project flavors and automatic FVM upgrades are outside the MVP. FVM installation is available through the explicit Install FVM setup action.
- App cancellation does not coordinate with FVM commands started independently in Terminal. Avoid managing the same SDK concurrently outside the app.
- Actual SDK downloads, Developer ID signing, notarization, and execution on macOS 14 require separate environment validation.

## Live integration smoke tests

```sh
scripts/smoke-test.sh --read-only
scripts/smoke-test.sh --isolated
```

Read-only mode queries your real FVM SDK list and live release catalog. Isolated mode creates a synthetic, already-cached SDK and a project under a new `/private/tmp/fvm-gui-smoke-*` directory, then exercises FVM's existing-cache install, global selection, project use, and removal through the production executor/service. It overrides `FVM_CACHE_PATH` and removes the temporary directory on exit. This validates CLI integration and postconditions, not a real Flutter download or working SDK. It never downloads an SDK or changes a registered user project.

## Verification on 2026-10-20

- Xcode 27.2 / Swift 6.4, Apple Silicon: Debug/Release builds and **42 XCTest tests passed**.
- Live FVM 4.3.1 read-only integration: **2 installed SDKs / 739 releases** decoded successfully.
- Isolated real-CLI integration: existing synthetic SDK install, global, project use/inspection, and removal passed. User SDKs/projects were not modified.
- UI visual inspection of Light/Dark Mode and complete interactive flows remains unverified because the UI inspection tool was interrupted. Native SwiftUI accessibility behavior is used, but VoiceOver has not been manually audited.
- A real SDK download, execution on macOS 14, and Developer ID signing/notarization remain unverified.

### Dependency Setup validation

- 18 new mocked tests cover Apple Silicon/Intel discovery candidates, custom paths with spaces, Dart Pub detection, invalid overrides, Homebrew validation, missing-dependency states, launch bypass, real-time stdout/stderr forwarding, install arguments, permission/nonzero failures, verification failure after successful exit, cancellation and installation locking.
- Read-only live detection passed with Homebrew 7.0.9 (`/opt/homebrew`) and FVM 4.3.1 on this Apple Silicon machine.
- The executor now awaits its termination callback asynchronously; this fixes an intermittent `Process.waitUntilExit()` hang observed during cancellation/timeout regression tests.
- Fresh `brew install fvm`, a physical Intel Mac, actual permission/network failure during a Homebrew install, clipboard/browser buttons, and manual interactive setup UI were not exercised. Installation scenarios use mocked execution and never uninstall/reinstall the existing working FVM.

## Shared infrastructure review (2026-10-20)

The existing architecture is retained: `FVMGUIApp` owns `AppContainer`, the composition root for constructor injection. `ContentView` owns the `NavigationSplitView` selection for SDKs, releases, registered projects, and Activity. `SDKViewModel` and `DependencySetupViewModel` hold main-actor observable UI state. `FVMCLIService`, `DependencySetupService`, `HomebrewLocator`, and `ProjectService` isolate service work with actors. Value models and `FVMParser` remain Sendable; FVM still owns SDK changes and the service still verifies their postconditions.

Shared components:

- `CLIExecutor` retains direct Foundation `Process` execution, array arguments, custom working directories, concurrent stdout/stderr streaming with split UTF-8 preservation, timeouts, cancellation, and process-group cleanup. Blocking pipe reads occur in detached readers, never on the main actor. Cancellation now respects the TERM grace period before escalating to KILL.
- `CLIExecutor(environment:overrides:)` provides per-instance environment injection. The base receives existing GUI PATH defaults, then explicit overrides win, including an exact PATH override. Environment values are never interpolated into shell commands or logged. Inject a separately configured executor where a service needs its own environment; the existing `CLIExecuting` signature and mocks remain compatible.
- `CLIError` distinguishes missing/non-executable paths, launch failures, timeouts, and nonzero exits. Cancellation remains `CancellationError`. The executor returns nonzero statuses intact; services opt into throwing via `CLIResult.requireSuccess`. FVM query errors still omit raw `api context` stdout.
- `LongRunningOperation` owns one task, typed idle/running/completed/failed/cancelled state, optional measured progress, error retention, cancellation, and an awaitable completion. Overlapping starts are rejected until cleanup completes. SDK mutations now use it; existing Setup task ownership and cancellation forwarding are retained. Actions must cooperate with cancellation and place blocking work in services. Actions are entered even on immediate cancellation so caller-owned cleanup runs.
- `OperationProgress` supports a message with an optional bounded fraction. Unknown progress remains indeterminate; CLI output is not converted into invented percentages.
- `LocalFileSystem` implements injectable `FileSystemOperating` on an actor, with directory enumeration, canonical-path-safe symlink metadata, reads, atomic writes, existence/directory checks, creation, and removal. Project discovery and project manifest inspection use it; Foundation errors propagate to visible scan issues and cancellation is checked throughout traversal.
- `ProjectDiscoveryService` scans only user-selected roots, applies a configurable depth, skips excluded folders and symlinks, parses YAML with Yams, bounds manifest/config sizes, reports malformed or unreadable locations, and merges duplicate roots without losing the nearest applicable `.fvmrc`.
- `ProjectDiscoveryViewModel` exposes typed scan state and progress to a native Projects sheet. Approved roots and read-only security-scoped bookmarks, ignored canonical paths, the last successful scan date, and backward-compatible registered project metadata persist through the existing UserDefaults store. Imports deduplicate canonical paths.
- `ActivityStore` retains bounded, in-memory UI logs and now stores typed operation status. `LoggingCLIExecutor` retains its API-query summary/redaction policy; SDK and Homebrew mutations continue streaming through their existing feature-owned log entries to avoid duplicate logs. Discovery is integrated into Projects. Yams 6.2.2 is the sole added dependency and supplies structural YAML parsing.

Validation: **63 XCTest tests passed**, including nine project discovery tests covering Flutter apps/packages/plugins, Dart-only packages, nested projects, inherited configuration, overlapping roots, ignored paths, excluded folders, malformed YAML, file and directory symlinks, inaccessible directories, cancellation, bookmark metadata, and import persistence. Existing infrastructure and service tests also pass. All discovery tests use temporary directories and no SDK downloads. The isolated real-FVM 4.3.1 smoke test passed synthetic cached install/global/use/remove and project inspection; it used a temporary cache and downloaded no SDKs.

Debug/test and universal Release (arm64/x86_64) builds were checked with Xcode 27.2 and Swift 6 strict concurrency. No Swift concurrency warnings were emitted. Xcode reports the App Intents metadata extraction warning because this application has no AppIntents dependency.

Limits: output capture remains in memory until command completion, while displayed Activity output is capped. Streaming handlers must return promptly; a handler that never returns can delay completion. Process-group cleanup cannot guarantee termination of descendants that deliberately detach into another session/group. Synchronous filesystem operations already in progress cannot be interrupted. Discovery UI was validated by build and model tests, not manual interaction or VoiceOver review. This app target currently disables App Sandbox; security-scoped bookmark creation and resolution are included for sandboxed deployments but were not runtime-tested with sandbox entitlement enabled. Real SDK downloads, macOS 14 runtime behavior, signing, and notarization remain unverified. Storage Manager, Compatibility Checker, and Flutter Doctor are not implemented.
