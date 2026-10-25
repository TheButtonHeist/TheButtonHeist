# Install TheInsideJob

Choose one runtime for your app:

| Install path | App build | Release behavior |
|---|---|---|
| Prebuilt XCFramework | Links one compiled dynamic framework | Build settings exclude it outside `Debug`. |
| Swift package | Compiles the runtime sources | Release compilation excludes the server through `#if DEBUG`. |

Both paths require iOS 16+. The runtime and CLI must use exactly the same release.
Do not combine source and prebuilt copies of these modules in one app.

## Install the CLI

```bash
brew install TheButtonHeist/tap/buttonheist
buttonheist --version
```

This formula installs the CLI/MCP and plan compiler files. It requires an
Apple Silicon Mac with macOS 14+. Install the iOS runtime separately below.

## Use the prebuilt bundle

### 1. Copy the runtime into your project

Run these commands from your app's project directory:

```bash
brew install TheButtonHeist/tap/theinsidejob
ditto "$(brew --prefix theinsidejob)/libexec/TheInsideJob.xcframework" ./TheInsideJob.xcframework
```

Use the same release as `buttonheist --version`. For a pinned download in CI,
use the GitHub release:

```bash
set -e
VERSION="$(buttonheist --version)"
RELEASE="https://github.com/TheButtonHeist/TheButtonHeist/releases/download/v$VERSION"

curl -fLO "$RELEASE/theinsidejob-$VERSION.zip"
curl -fLO "$RELEASE/checksums.txt"
awk -v file="theinsidejob-$VERSION.zip" '$2 == file' checksums.txt | shasum -a 256 -c
ditto -x -k "theinsidejob-$VERSION.zip" .
```

Both paths provide `TheInsideJob.xcframework`. It contains device and simulator
slices, statically linked dependencies, resources, symbols, and licenses. `VERSION` records the release. `XCODE_VERSION` records its compiler.

Pin the release and its SHA-256 checksum in your app's dependency setup.

### 2. Add the framework to Tuist

Merge these arguments into your app target:

```swift
dependencies: [
    .xcframework(path: "TheInsideJob.xcframework"),
],
settings: .settings(
    base: ["EXCLUDED_SOURCE_FILE_NAMES": "$(inherited) TheInsideJob.*framework"],
    configurations: [
        .debug(name: "Debug", settings: [
            "INCLUDED_SOURCE_FILE_NAMES": "$(inherited) TheInsideJob.*framework",
        ]),
        .release(name: "Release"),
    ]
)
```

These settings exclude the framework by default. The `Debug` configuration
includes it through `INCLUDED_SOURCE_FILE_NAMES`. Keep your other configurations
and existing exclusion patterns when you merge these settings.

Generate the project with `tuist generate --no-open`. Build and run your app in
`Debug`. The runtime starts automatically. No Swift import or startup call is required.

Other configurations exclude the runtime from linking and embedding. For custom
debug configurations, add the same `INCLUDED_SOURCE_FILE_NAMES` setting.

[Complete prebuilt app](../tests/fixtures/insidejob-binary-consumer/Project.swift)

## Compile from source

In Xcode, add this package at the exact version from `buttonheist --version`:

```text
https://github.com/TheButtonHeist/TheButtonHeist
```

Add the `TheInsideJob` product to your app target.

For Tuist, add the package to your project's `packages` argument:

```swift
packages: [
    .remote(
        url: "https://github.com/TheButtonHeist/TheButtonHeist",
        requirement: .exact("0.7.0")
    ),
],
```

Replace `0.7.0` with the exact version from `buttonheist --version`.

Add the product to your app target's `dependencies` argument:

```swift
dependencies: [.package(product: "TheInsideJob")],
```

Generate the project with `tuist generate --no-open`. Build and run your app in
`Debug`.

The package compiles with your app. Its Objective-C loader starts the runtime
automatically. No Swift import or startup call is required. Release compilation
excludes the server code and loader through `#if DEBUG`.

[Complete source app](../tests/fixtures/insidejob-source-consumer/Project.swift)
uses a local checkout so CI compiles the current commit.

## Verify Release behavior

For a prebuilt install, verify that the final app archive excludes
`TheInsideJob.framework`. The host's `#if DEBUG` cannot disable code
inside a precompiled Debug binary. The build settings exclude that framework.

For a source install, build the package in Release with your app. The package's
compile conditions exclude the server.

Both paths use the same runtime. Connection instructions are in
[API configuration](API.md#configuration) and
[USB connectivity](USB_DEVICE_CONNECTIVITY.md).

The prebuilt framework supports automatic loading. Use the source package
when your app needs to import TheInsideJob's Swift API.

## Inject into a development app

Injection supports tools that install and launch an app without changes to its project.
The runtime still comes from the same published `TheInsideJob.xcframework`.

1. Select the `ios-arm64` device slice from the XCFramework's `Info.plist`.
2. Copy its `TheInsideJob.framework` into the built app's `Frameworks` directory.
3. Sign the framework with the app's development identity.
4. Sign the app with its existing identity, profile, and entitlements.
5. Install the app on the device.
6. Launch the app with this environment:

```text
DYLD_INSERT_LIBRARIES=@executable_path/Frameworks/TheInsideJob.framework/TheInsideJob
INSIDEJOB_PORT=27182
INSIDEJOB_TOKEN=your-token
INSIDEJOB_ID=your-session
INSIDEJOB_SCOPE=usb
INSIDEJOB_FINGERPRINTS=false
```

The port and token above are examples. Supply values for your session.
For a simulator, select its slice and use `INSIDEJOB_SCOPE=simulator`.
Pass simulator launch variables through `SIMCTL_CHILD_`, including `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`.

The Objective-C loader starts the runtime. The host executable requires no link or import.
A normal launch without `DYLD_INSERT_LIBRARIES` leaves the copied framework unloaded.
The framework contains its dependencies and resource bundles; keep that directory intact.
Use one runtime copy per app. An app that already links TheInsideJob requires no injected copy.

The host's compile conditions cannot disable an injected Debug framework.
Use development app copies for injection and exclude that framework from distribution archives.
The integration check covers an unlinked host, launch-time injection, and public Swift interaction.
