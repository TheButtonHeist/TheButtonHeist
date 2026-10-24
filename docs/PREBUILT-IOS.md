# Prebuilt iOS runtime

Each release includes `theinsidejob-<version>.zip`. It contains the Debug runtime
as device and simulator XCFrameworks, its binary dependencies, resource bundles,
debug symbols, and an integration script. The minimum iOS version is 16.

The runtime and CLI must have exactly the same release version. `VERSION` records
the runtime version. `XCODE_VERSION` records the compiler used to produce it.

## Download

Download the archive from the matching GitHub release, verify it against
`checksums.txt`, and extract it into your project as `TheInsideJob/`. Pin the
release URL and checksum in your dependency setup so CI uses the same binaries.

## Tuist integration

Add every XCFramework under `TheInsideJob/XCFrameworks/` as an optional dependency:

```swift
dependencies: [
    .xcframework(
        path: "TheInsideJob/XCFrameworks/TheInsideJob.xcframework",
        status: .optional
    ),
    // Add the other XCFrameworks in that directory with the same status.
]
```

Use the directory listing to include all dependencies. A complete working
manifest is in `tests/fixtures/insidejob-binary-consumer/Project.swift` in the
Button Heist repository. Do not combine the prebuilt bundle with source-built
copies of these modules in the same app.

Add this script as the final post-build phase, after framework embedding:

```swift
scripts: [
    .post(
        path: "TheInsideJob/Scripts/integrate-insidejob.sh",
        name: "Integrate TheInsideJob",
        basedOnDependencyAnalysis: false
    ),
]
```

Set `ENABLE_USER_SCRIPT_SANDBOXING` to `NO` for that app target so the script can
remove embedded frameworks. Keep the script after all other embedding phases.

For the `Debug` configuration, the script copies platform-specific resources
into the app. For every other configuration, it removes the distributed
frameworks and resources. Optional linking lets those apps launch without the
runtime. Custom debug configurations must be added explicitly to the script's
configuration check before using the runtime.

No Swift import or startup code is needed: the Objective-C load hook starts the
runtime. This bundle is intended for automatic loading. It does not promise
Swift module compatibility across compiler versions; use the source package for
manual Swift API integration across toolchains.

## Verify the app

Build and run Debug, then connect with the matching CLI and request an interface.
Build and run Release, then verify the distributed frameworks are absent from
the app's `Frameworks/` directory. Also inspect your final archive before shipping.

The Debug binary keeps its server code wherever it is embedded. The host's
`#if DEBUG` settings do not disable a precompiled binary. This integration follows
[Reveal's model](https://support.revealapp.com/article/39-integrating-reveal-via-linking):
exclude the binary from production apps instead of depending on a runtime check.
Never ship an app containing the Debug runtime.
