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
        requirement: .exact("0.6.38")
    ),
],
```

Replace `0.6.38` with the exact version from `buttonheist --version`.

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
