# Install TheInsideJob

Choose one runtime for your app:

| Install path | App build | Release behavior |
|---|---|---|
| Prebuilt XCFramework | Links one compiled dynamic framework | The integration script removes it outside `Debug`. |
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
slices, statically linked dependencies, resources, symbols, licenses, and the
integration script. `VERSION` records the release. `XCODE_VERSION` records its compiler.

Pin the release and its SHA-256 checksum in your app's dependency setup.

### 2. Add the framework to Tuist

Merge these arguments into your app target:

```swift
scripts: [
    .post(
        path: "TheInsideJob.xcframework/Scripts/integrate-insidejob.sh",
        name: "Integrate TheInsideJob",
        basedOnDependencyAnalysis: false
    ),
],
dependencies: [
    .xcframework(path: "TheInsideJob.xcframework", status: .optional),
],
settings: .settings(base: ["ENABLE_USER_SCRIPT_SANDBOXING": "NO"])
```

Keep the integration script last, after framework embedding. Use `.optional`
so Release can run without the framework.

Generate the project with `tuist generate --no-open`. Build and run your app in
`Debug`. The runtime starts automatically. No Swift import or startup call is required.

The script removes `TheInsideJob.framework`, including its resources, from every
other build configuration. For custom debug configurations, add their names to
the script's configuration check. The default check accepts only `Debug`.

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
inside a precompiled Debug binary. The final build phase removes that framework.

For a source install, build the package in Release with your app. The package's
compile conditions exclude the server.

Both paths use the same runtime. Connection instructions are in
[API configuration](API.md#configuration) and
[USB connectivity](USB_DEVICE_CONNECTIVITY.md).

The prebuilt path uses
[Reveal's integration model](https://support.revealapp.com/article/39-integrating-reveal-via-linking).
The prebuilt framework supports automatic loading. Use the source package
when your app needs to import TheInsideJob's Swift API.
