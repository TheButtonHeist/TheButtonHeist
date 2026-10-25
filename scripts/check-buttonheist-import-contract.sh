#!/usr/bin/env bash
# Compile an external SwiftPM consumer that imports ButtonHeist only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/buttonheist-external-import-contract"
AUTHORING_FIXTURE_DIR="$REPO_ROOT/tests/fixtures/theplans-authoring-import-contract"
PUBLIC_PRODUCTS_FIXTURE_DIR="$REPO_ROOT/tests/fixtures/buttonheist-public-products-import-contract"
IOS_PUBLIC_PRODUCTS_FIXTURE_DIR="$REPO_ROOT/tests/fixtures/buttonheist-ios-public-products-import-contract"
IOS_SIMULATOR_TRIPLE="${BUTTONHEIST_SWIFT_API_IOS_SIMULATOR_TRIPLE:-arm64-apple-ios17.0-simulator}"

fail() {
    echo "Error: $*" >&2
    exit 1
}

[[ -f "$FIXTURE_DIR/Package.swift" ]] || fail "missing external import fixture Package.swift"
[[ -f "$AUTHORING_FIXTURE_DIR/Package.swift" ]] || fail "missing ThePlans authoring import fixture Package.swift"
[[ -f "$PUBLIC_PRODUCTS_FIXTURE_DIR/Package.swift" ]] || fail "missing public products import fixture Package.swift"
[[ -f "$IOS_PUBLIC_PRODUCTS_FIXTURE_DIR/Package.swift" ]] || fail "missing iOS public products import fixture Package.swift"

if grep -n 'ButtonHeistDSL' "$REPO_ROOT/Package.swift" "$REPO_ROOT/Project.swift"; then
    fail "ButtonHeistDSL must not remain a product, target, or scheme; import ThePlans directly"
fi
[[ ! -e "$REPO_ROOT/ButtonHeist/Sources/ButtonHeistDSL" ]] \
    || fail "removed ButtonHeistDSL source facade directory still exists"

normalize_exported_imports() {
    sed -E \
        -e "s#^$REPO_ROOT/##" \
        -e 's#:[0-9]+:[[:space:]]*@_exported[[:space:]]+import[[:space:]]+#:#'
}

EXPORTED_IMPORTS="$(grep -R -nE '^[[:space:]]*@_exported[[:space:]]+import[[:space:]]+' "$REPO_ROOT/ButtonHeist/Sources" | normalize_exported_imports || true)"
EXPECTED_EXPORTED_IMPORTS="$(cat <<EOF
ButtonHeist/Sources/ButtonHeistTesting/ButtonHeistTesting.swift:ThePlans
ButtonHeist/Sources/TheButtonHeist/Exports.swift:ThePlans
ButtonHeist/Sources/TheInsideJob/Heist.swift:TheScore
EOF
)"
if [[ "$(printf '%s\n' "$EXPORTED_IMPORTS" | sort)" != "$(printf '%s\n' "$EXPECTED_EXPORTED_IMPORTS" | sort)" ]]; then
    printf 'Observed @_exported imports:\n%s\n' "$EXPORTED_IMPORTS" >&2
    fail "@_exported imports must match the package-contract allowlist"
fi

IMPORTS="$(grep -R -nE '^[[:space:]]*import[[:space:]]+' "$FIXTURE_DIR/Sources" || true)"
[[ -n "$IMPORTS" ]] || fail "external import fixture must import ButtonHeist"
if printf '%s\n' "$IMPORTS" \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*import[[:space:]]+ButtonHeist([[:space:]]|$)'
then
    fail "external import fixture must import ButtonHeist only"
fi

if grep -nE 'product:[[:space:]]*"ThePlans"|name:[[:space:]]*"ThePlans"' "$FIXTURE_DIR/Package.swift"; then
    fail "external import fixture must depend on the ButtonHeist product only, not ThePlans"
fi

AUTHORING_IMPORTS="$(grep -R -nE '^[[:space:]]*import[[:space:]]+' "$AUTHORING_FIXTURE_DIR/Sources" || true)"
[[ -n "$AUTHORING_IMPORTS" ]] || fail "authoring import fixture must import ThePlans"
if printf '%s\n' "$AUTHORING_IMPORTS" \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*import[[:space:]]+ThePlans([[:space:]]|$)'
then
    fail "authoring import fixture must import ThePlans only"
fi

if grep -nE 'product:[[:space:]]*"ButtonHeistDSL"|name:[[:space:]]*"ButtonHeistDSL"' "$AUTHORING_FIXTURE_DIR/Package.swift"; then
    fail "authoring import fixture must depend on ThePlans directly, not the removed ButtonHeistDSL facade"
fi

PUBLIC_PRODUCT_IMPORTS="$(grep -R -nE '^[[:space:]]*import[[:space:]]+' "$PUBLIC_PRODUCTS_FIXTURE_DIR/Sources" || true)"
for product in ThePlans TheScore ButtonHeist; do
    if ! printf '%s\n' "$PUBLIC_PRODUCT_IMPORTS" \
        | grep -Eq "^[^:]+:[0-9]+:[[:space:]]*import[[:space:]]+$product([[:space:]]|$)"
    then
        fail "public products import fixture must import $product"
    fi
    if ! grep -Eq "\\.product\\(name:[[:space:]]*\"$product\"" "$PUBLIC_PRODUCTS_FIXTURE_DIR/Package.swift"; then
        fail "public products import fixture must depend on $product"
    fi
done

IOS_PUBLIC_PRODUCT_IMPORTS="$(grep -R -nE '^[[:space:]]*import[[:space:]]+' "$IOS_PUBLIC_PRODUCTS_FIXTURE_DIR/Sources" || true)"
for product in TheInsideJob ButtonHeistTesting; do
    if ! printf '%s\n' "$IOS_PUBLIC_PRODUCT_IMPORTS" \
        | grep -Eq "^[^:]+:[0-9]+:[[:space:]]*import[[:space:]]+$product([[:space:]]|$)"
    then
        fail "iOS public products import fixture must import $product"
    fi
    if ! grep -Eq "\\.product\\(name:[[:space:]]*\"$product\"" "$IOS_PUBLIC_PRODUCTS_FIXTURE_DIR/Package.swift"; then
        fail "iOS public products import fixture must depend on $product"
    fi
done

SCRATCH_PATH="$(mktemp -d "${TMPDIR:-/tmp}/buttonheist-import-contract-build.XXXXXX")"
SWIFT_CACHE_PATH="$(mktemp -d "${TMPDIR:-/tmp}/buttonheist-import-contract-cache.XXXXXX")"
cleanup() {
    rm -rf "$SCRATCH_PATH"
    rm -rf "$SWIFT_CACHE_PATH"
    rm -f "$FIXTURE_DIR/Package.resolved"
    rm -f "$AUTHORING_FIXTURE_DIR/Package.resolved"
    rm -f "$PUBLIC_PRODUCTS_FIXTURE_DIR/Package.resolved"
    rm -f "$IOS_PUBLIC_PRODUCTS_FIXTURE_DIR/Package.resolved"
}
trap cleanup EXIT

build_fixture() {
    local fixture_dir="$1"
    shift
    local scratch_dir
    scratch_dir="$SCRATCH_PATH/$(basename "$fixture_dir")"

    CLANG_MODULE_CACHE_PATH="$SWIFT_CACHE_PATH/clang" \
        swift build \
        --disable-sandbox \
        --cache-path "$SWIFT_CACHE_PATH/swiftpm" \
        --package-path "$fixture_dir" \
        --scratch-path "$scratch_dir" \
        "$@"
}

build_fixture "$FIXTURE_DIR"
build_fixture "$AUTHORING_FIXTURE_DIR"
build_fixture "$PUBLIC_PRODUCTS_FIXTURE_DIR"
build_fixture \
    "$IOS_PUBLIC_PRODUCTS_FIXTURE_DIR" \
    --triple "$IOS_SIMULATOR_TRIPLE" \
    --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -Xswiftc -DDEBUG

NEGATIVE_THEPLANS_PROBE_DIR="$SCRATCH_PATH/theplans-negative-import-probes"
NEGATIVE_BUTTONHEIST_PROBE_DIR="$SCRATCH_PATH/buttonheist-negative-import-probes"
mkdir -p \
    "$NEGATIVE_THEPLANS_PROBE_DIR/Sources/ThePlansNegativeTheScoreImportProbe" \
    "$NEGATIVE_BUTTONHEIST_PROBE_DIR/Sources/ButtonHeistNegativeTheInsideJobImportProbe" \
    "$NEGATIVE_BUTTONHEIST_PROBE_DIR/Sources/ButtonHeistNegativeTheScoreSymbolProbe" \
    "$NEGATIVE_BUTTONHEIST_PROBE_DIR/Sources/ButtonHeistNegativeTestingImportProbe"
cat > "$NEGATIVE_THEPLANS_PROBE_DIR/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThePlansNegativeImportProbes",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "ButtonHeist", path: "$REPO_ROOT")
    ],
    targets: [
        .executableTarget(
            name: "ThePlansNegativeTheScoreImportProbe",
            dependencies: [
                .product(name: "ThePlans", package: "ButtonHeist")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
EOF
cat > "$NEGATIVE_BUTTONHEIST_PROBE_DIR/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ButtonHeistNegativeImportProbes",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "ButtonHeist", path: "$REPO_ROOT")
    ],
    targets: [
        .executableTarget(
            name: "ButtonHeistNegativeTheInsideJobImportProbe",
            dependencies: [
                .product(name: "ButtonHeist", package: "ButtonHeist")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ButtonHeistNegativeTestingImportProbe",
            dependencies: [
                .product(name: "ButtonHeist", package: "ButtonHeist")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ButtonHeistNegativeTheScoreSymbolProbe",
            dependencies: [
                .product(name: "ButtonHeist", package: "ButtonHeist")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
EOF
cat > "$NEGATIVE_BUTTONHEIST_PROBE_DIR/Sources/ButtonHeistNegativeTheInsideJobImportProbe/main.swift" <<'EOF'
import TheInsideJob

print("TheInsideJob must not be importable through ButtonHeist")
EOF
cat > "$NEGATIVE_BUTTONHEIST_PROBE_DIR/Sources/ButtonHeistNegativeTestingImportProbe/main.swift" <<'EOF'
import ButtonHeistTesting

print("ButtonHeistTesting must not be importable through ButtonHeist")
EOF
cat > "$NEGATIVE_BUTTONHEIST_PROBE_DIR/Sources/ButtonHeistNegativeTheScoreSymbolProbe/main.swift" <<'EOF'
import ButtonHeist

let value: HeistValue? = nil
print(value as Any)
EOF
cat > "$NEGATIVE_THEPLANS_PROBE_DIR/Sources/ThePlansNegativeTheScoreImportProbe/main.swift" <<'EOF'
import TheScore

print("TheScore must not be importable through ThePlans")
EOF

negative_probe() {
    local probe_dir="$1"
    local target="$2"
    local expected_pattern="$3"
    local failure="$4"
    local output

    if output="$(build_fixture "$probe_dir" --target "$target" 2>&1)"; then
        [[ -z "$output" ]] || printf '%s\n' "$output" >&2
        fail "$failure"
    fi
    if ! grep -Eq "$expected_pattern" <<< "$output"; then
        printf '%s\n' "$output" >&2
        fail "$target failed without the expected diagnostic: $expected_pattern"
    fi
}

negative_probe \
    "$NEGATIVE_BUTTONHEIST_PROBE_DIR" \
    "ButtonHeistNegativeTheInsideJobImportProbe" \
    "(no such module|unable to resolve module dependency:) 'TheInsideJob'" \
    "ButtonHeist exposed disallowed import TheInsideJob"
negative_probe \
    "$NEGATIVE_BUTTONHEIST_PROBE_DIR" \
    "ButtonHeistNegativeTestingImportProbe" \
    "(no such module|unable to resolve module dependency:) 'ButtonHeistTesting'" \
    "ButtonHeist exposed disallowed import ButtonHeistTesting"
negative_probe \
    "$NEGATIVE_BUTTONHEIST_PROBE_DIR" \
    "ButtonHeistNegativeTheScoreSymbolProbe" \
    "cannot find type 'HeistValue' in scope" \
    "ButtonHeist re-exported TheScore symbols"
negative_probe \
    "$NEGATIVE_THEPLANS_PROBE_DIR" \
    "ThePlansNegativeTheScoreImportProbe" \
    "(no such module|unable to resolve module dependency:) 'TheScore'" \
    "ThePlans exposed disallowed import TheScore"
