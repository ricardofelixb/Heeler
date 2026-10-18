#!/bin/bash
# Dedicated simulator and local dependency sources for one persistent CI runner.
set -euo pipefail
: "${GITHUB_ENV:?Run as a GitHub Actions preparation step}"
: "${RUNNER_TEMP:?Missing runner temp directory}"
: "${RUNNER_TOOL_CACHE:?Missing runner tool cache}"
: "${DEVELOPER_DIR:?Select the local Xcode installation}"
printf 'DEVELOPER_DIR=%s\nHEELER_CI_OVERLAP_BUILD=0\n' "$DEVELOPER_DIR" >> "$GITHUB_ENV"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "Heeler's local iOS runner requires Apple Silicon macOS." >&2
    exit 1
fi
if ! /usr/bin/sudo -n /usr/bin/true; then
    echo "Install the explicitly approved CI fixture sudoers policy; see docs/guides/self-hosted-ios-ci.md." >&2
    exit 1
fi
xcodebuild -version
xcodebuild -version | grep -q '^Xcode 26\.' || { echo 'Expected Xcode 26.x' >&2; exit 1; }
# No erase/shutdown/reset of a shared or interactive simulator. Reuse only our named device.
python3 - "$GITHUB_ENV" <<'PY'
import json, subprocess, sys
name = "Heeler CI iPhone 17"
listing = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "--json"]))
runtimes = [r for r in listing["runtimes"] if r.get("isAvailable") and
            r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-26-")]
if not runtimes:
    raise SystemExit("Install an available iOS 26 runtime in Xcode first")
runtime = max(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))
devices = [d for d in listing["devices"].get(runtime["identifier"], [])
           if d.get("isAvailable") and d["name"] == name]
udid = devices[0]["udid"] if devices else subprocess.check_output([
    "xcrun", "simctl", "create", name, "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
    runtime["identifier"]], text=True).strip()
with open(sys.argv[1], "a") as output:
    output.write(f"HEELER_CI_SIMULATOR_UDID={udid}\nHEELER_CI_SIMULATOR_NAME={name}\n")
print(f"Dedicated CI simulator: {name} ({udid})")
PY
if [[ "${CACHE_MODE:-warm}" == cold ]]; then
    packages="$(mktemp -d "$RUNNER_TEMP/heeler-cold-spm.XXXXXX")"
else
    packages="$RUNNER_TOOL_CACHE/heeler-source-packages"
    mkdir -p "$packages"
fi
printf 'HEELER_CI_SOURCE_PACKAGES_DIR=%s\n' "$packages" >> "$GITHUB_ENV"
