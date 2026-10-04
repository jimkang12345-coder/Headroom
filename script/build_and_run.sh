#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_MAC=1
BUILD_IOS=0
LAUNCH=1
FIXTURE_MODE=0
APP_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all) BUILD_MAC=1; BUILD_IOS=1 ;;
        --ios) BUILD_MAC=0; BUILD_IOS=1 ;;
        --mac) BUILD_MAC=1; BUILD_IOS=0 ;;
        --build-only) LAUNCH=0 ;;
        --fixture) FIXTURE_MODE=1 ;;
        --) shift; APP_ARGS=("$@"); break ;;
        *) APP_ARGS+=("$1") ;;
    esac
    shift
done

if [[ ${FIXTURE_MODE} -eq 1 && ${BUILD_IOS} -eq 1 ]]; then
    printf '%s\n' '--fixture supports the Mac target only.' >&2
    exit 2
fi

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/headroom-run.XXXXXX")"
STAGE_DIR="${RUN_DIR}/source"
DERIVED_DATA_DIR="${RUN_DIR}/DerivedData"
BUILD_CACHE_DIR="${RUN_DIR}/SwiftBuild"
mkdir -p "${STAGE_DIR}" "${RUN_DIR}/logs"
if [[ ${FIXTURE_MODE} -eq 1 ]]; then
    mkdir -m 700 "${RUN_DIR}/FixtureData"
fi
printf 'Build and evidence directory: %s\n' "${RUN_DIR}"

# Copy only the app inputs, with all caches and prior handoffs excluded.
for component in HeadroomCore HeadroomMac HeadroomIOS Headroom.xcodeproj script; do
    rsync -a --exclude='.build' --exclude='.swiftpm' --exclude='.DS_Store' \
        --exclude='xcuserdata' --exclude='.handoffs' \
        "${PROJECT_ROOT}/${component}" "${STAGE_DIR}/"
done
python3 - "${PROJECT_ROOT}" "${STAGE_DIR}" "${RUN_DIR}/source-provenance.json" <<'PY'
from pathlib import Path
import datetime, hashlib, json, sys
original, stage, dest = map(Path, sys.argv[1:])
files=[]
for path in sorted(stage.rglob('*')):
    if path.is_file():
        rel=path.relative_to(stage)
        data=path.read_bytes()
        source=original/rel
        if source.read_bytes()!=data:
            raise SystemExit('Source changed during staging: '+str(rel))
        files.append({'path':str(rel),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})
dest.write_text(json.dumps({'captured_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'original_root':str(original),'staged_root':str(stage),'files':files},indent=2))
PY
# Generate only inside the owned stage. The checkout is never rewritten by a build.
python3 "${STAGE_DIR}/script/generate_project.py" | tee "${RUN_DIR}/logs/project-generation.log"
shasum -a 256 "${STAGE_DIR}/Headroom.xcodeproj/project.pbxproj" > "${RUN_DIR}/generated-project.sha256"
swift test --package-path "${STAGE_DIR}/HeadroomCore" --build-path "${BUILD_CACHE_DIR}" \
    2>&1 | tee "${RUN_DIR}/logs/swift-test.log"

if [[ ${BUILD_MAC} -eq 1 ]]; then
    xcodebuild build -project "${STAGE_DIR}/Headroom.xcodeproj" \
        -scheme HeadroomMac -configuration Debug -destination 'platform=macOS' \
        -derivedDataPath "${DERIVED_DATA_DIR}" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY='-' \
        2>&1 | tee "${RUN_DIR}/logs/xcodebuild-mac.log"
    MAC_APP="${DERIVED_DATA_DIR}/Build/Products/Debug/HeadroomMac.app"
    if [[ ${LAUNCH} -eq 1 ]]; then
        # A new instance uses this exact build. No prior PID or unrelated process is terminated.
        if [[ ${FIXTURE_MODE} -eq 1 ]]; then
            open -n "${MAC_APP}" --env "HEADROOM_FIXTURE_DIR=${RUN_DIR}/FixtureData" --args ${APP_ARGS[@]+"${APP_ARGS[@]}"}
        else
            open -n "${MAC_APP}" --args ${APP_ARGS[@]+"${APP_ARGS[@]}"}
        fi
        printf 'Launched Mac app: %s\n' "${MAC_APP}"
    fi
fi

if [[ ${BUILD_IOS} -eq 1 ]]; then
    SIM_INFO="$(python3 - "${IOS_SIM_ID:-}" <<'PY'
import json, subprocess, sys
payload=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j']))
devices=[(runtime,d) for runtime,items in payload['devices'].items() if 'iOS' in runtime
         for d in items if d.get('isAvailable')]
requested=sys.argv[1]
if requested:
    devices=[item for item in devices if item[1]['udid']==requested]
if not devices:
    raise SystemExit('No matching available iOS simulator. Set IOS_SIM_ID to an available identifier.')
devices.sort(key=lambda item:(item[1]['state']=='Booted','iPhone' in item[1]['name'],item[0]),reverse=True)
d=devices[0][1]
print('|'.join([d['udid'],d['name'],d['state']]))
PY
)"
    IFS='|' read -r SIM_ID SIM_NAME SIM_STATE <<< "${SIM_INFO}"
    printf 'Selected simulator: %s (%s)\n' "${SIM_NAME}" "${SIM_ID}"
    xcodebuild build -project "${STAGE_DIR}/Headroom.xcodeproj" \
        -scheme HeadroomIOS -configuration Debug -destination "platform=iOS Simulator,id=${SIM_ID}" \
        -derivedDataPath "${DERIVED_DATA_DIR}" CODE_SIGNING_ALLOWED=NO \
        2>&1 | tee "${RUN_DIR}/logs/xcodebuild-ios.log"
    IOS_APP="${DERIVED_DATA_DIR}/Build/Products/Debug-iphonesimulator/HeadroomIOS.app"
    if [[ ${LAUNCH} -eq 1 ]]; then
        if [[ "${SIM_STATE}" != 'Booted' ]]; then xcrun simctl boot "${SIM_ID}"; fi
        xcrun simctl bootstatus "${SIM_ID}" -b
        xcrun simctl install "${SIM_ID}" "${IOS_APP}"
        xcrun simctl launch "${SIM_ID}" org.headroom.ios ${APP_ARGS[@]+"${APP_ARGS[@]}"}
    fi
fi
printf 'Completed. Source hashes, build logs and artifacts retained at %s\n' "${RUN_DIR}"
