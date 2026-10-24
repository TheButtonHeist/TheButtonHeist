# Install TheInsideJob

Choose one runtime for your app:

| Install path | App build | Release behavior |
|---|---|---|
| Prebuilt XCFrameworks | Links compiled dynamic frameworks | The integration script removes them outside `Debug`. |
| Swift package | Compiles the runtime sources | Release compilation excludes the server through `#if DEBUG`. |

Both paths require iOS 16+. The runtime and CLI must use exactly the same release.
Do not combine source and prebuilt copies of these modules in one app.

## Install the CLI

```bash
brew install TheButtonHeist/tap/buttonheist
buttonheist --version
```

Homebrew installs the CLI/MCP and plan compiler files. It does not install the
iOS bundle. The Homebrew distribution requires an Apple Silicon Mac with
macOS 14+.

## Use the prebuilt bundle

### 1. Download the matching release

Run these commands from your app's project directory:

```bash
set -e
VERSION="$(buttonheist --version)"
RELEASE="https://github.com/TheButtonHeist/TheButtonHeist/releases/download/v$VERSION"

curl -fLO "$RELEASE/theinsidejob-$VERSION.zip"
curl -fLO "$RELEASE/checksums.txt"
awk -v file="theinsidejob-$VERSION.zip" '$2 == file' checksums.txt | shasum -a 256 -c
ditto -x -k "theinsidejob-$VERSION.zip" .
```

The zip extracts as `TheInsideJob/`. It contains device and simulator
XCFrameworks, dependencies, resources, symbols, licenses, and the integration
script. `VERSION` records the release. `XCODE_VERSION` records its compiler.

Pin the release and its SHA-256 checksum in your app's dependency setup.

### 2. Add the bundle to Tuist

Add this code before the project declaration in `Project.swift`:

```swift
import Foundation
import ProjectDescription

let bundlePath = "TheInsideJob"
let frameworksURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("\(bundlePath)/XCFrameworks")
let frameworks = try FileManager.default.contentsOfDirectory(atPath: frameworksURL.path)
    .filter { $0.hasSuffix(".xcframework") }
    .sorted()
```

Merge these arguments into your app target:

```swift
scripts: [
    .post(
        path: .relativeToManifest("\(bundlePath)/Scripts/integrate-insidejob.sh"),
        name: "Integrate TheInsideJob",
        basedOnDependencyAnalysis: false
    ),
],
dependencies: frameworks.map {
    .xcframework(path: .relativeToManifest("\(bundlePath)/XCFrameworks/\($0)"), status: .optional)
},
settings: .settings(base: ["ENABLE_USER_SCRIPT_SANDBOXING": "NO"])
```

Keep the integration script last, after all framework embedding. Use `.optional`
for every framework in the bundle.

Generate the project with `tuist generate --no-open`. Build and run your app in
`Debug`.

The runtime starts automatically. The script copies Debug resources and removes
all distributed frameworks and resources from every other build configuration.
Optional linking lets those builds run without the runtime.

For custom debug configurations, add their names to the script's configuration
check. The default check accepts only `Debug`.

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

For a prebuilt install, verify that the final app archive excludes every
distributed framework and resource. The host's `#if DEBUG` cannot disable code
inside a precompiled Debug binary. The final build phase removes those binaries.

For a source install, build the package in Release with your app. The package's
compile conditions exclude the server.

Both paths use the same runtime. Connection instructions are in
[API configuration](API.md#configuration) and
[USB connectivity](USB_DEVICE_CONNECTIVITY.md).

The prebuilt path uses
[Reveal's integration model](https://support.revealapp.com/article/39-integrating-reveal-via-linking).
It supports automatic loading. Swift API imports across compiler versions
remain outside the prebuilt contract. Use the source package for those imports.
