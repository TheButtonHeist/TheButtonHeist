#!/usr/bin/env bash
# Run a command with Button Heist result recording enabled.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${BUTTONHEIST_RESULTS_DIR:-}"
RESULTS_MODE="${BUTTONHEIST_RESULTS_MODE:-failures}"
IOS_SANDBOX=false

usage() {
    cat <<'EOF'
Usage: scripts/run-with-heist-results.sh [options] -- COMMAND [ARG...]

Options:
  --dir DIR       Directory for host-side result artifacts.
  --ios-sandbox  Use the process temp-directory sentinel for simulator-hosted tests.
  --mode MODE    Recording mode: failures, all, or off.
  -h, --help     Show this help.

The wrapper sets BUTTONHEIST_RESULTS_DIR and BUTTONHEIST_RESULTS_MODE.
With --ios-sandbox, it also sets SIMCTL_CHILD_* variables so simulator-hosted
test processes receive the same recording configuration. When SIM_UDID is
available, it also sets the simulator launchd environment used by xcodebuild
test runners.
The command's normal exit status is preserved.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            RESULTS_DIR="${2:-}"
            [[ -n "$RESULTS_DIR" ]] || {
                echo "Error: --dir requires a value" >&2
                exit 2
            }
            shift 2
            ;;
        --ios-sandbox)
            RESULTS_DIR="process-temporary-directory"
            IOS_SANDBOX=true
            shift
            ;;
        --mode)
            RESULTS_MODE="${2:-}"
            [[ -n "$RESULTS_MODE" ]] || {
                echo "Error: --mode requires a value" >&2
                exit 2
            }
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 2
fi

if [[ -z "$RESULTS_DIR" ]]; then
    RESULTS_DIR="$REPO_ROOT/.rp1/work/heist-results/manual"
fi

if [[ "$RESULTS_DIR" != "process-temporary-directory" ]]; then
    mkdir -p "$RESULTS_DIR"
fi

export BUTTONHEIST_RESULTS_DIR="$RESULTS_DIR"
export BUTTONHEIST_RESULTS_MODE="$RESULTS_MODE"

SIMCTL_LAUNCHD_ENV_APPLIED=false

cleanup() {
    local status=$?
    if [[ "$SIMCTL_LAUNCHD_ENV_APPLIED" == true ]]; then
        xcrun simctl spawn "$SIM_UDID" launchctl unsetenv BUTTONHEIST_RESULTS_DIR >/dev/null 2>&1 || true
        xcrun simctl spawn "$SIM_UDID" launchctl unsetenv BUTTONHEIST_RESULTS_MODE >/dev/null 2>&1 || true
    fi
    return "$status"
}
trap cleanup EXIT

if [[ "$IOS_SANDBOX" == true ]]; then
    export SIMCTL_CHILD_BUTTONHEIST_RESULTS_DIR="$RESULTS_DIR"
    export SIMCTL_CHILD_BUTTONHEIST_RESULTS_MODE="$RESULTS_MODE"
    if [[ -n "${SIM_UDID:-}" ]]; then
        xcrun simctl spawn "$SIM_UDID" launchctl setenv BUTTONHEIST_RESULTS_DIR "$RESULTS_DIR"
        xcrun simctl spawn "$SIM_UDID" launchctl setenv BUTTONHEIST_RESULTS_MODE "$RESULTS_MODE"
        SIMCTL_LAUNCHD_ENV_APPLIED=true
    fi
fi

"$@"
