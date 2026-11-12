#!/usr/bin/env bash
# Build phase: renders LaunchAgents/agent.plist.template into the app bundle as
# Contents/Library/LaunchAgents/<label>.plist, using the build's identity settings.
set -euo pipefail

: "${SRCROOT:?run from an Xcode build phase}"
: "${RESTOREY_AGENT_LABEL:?}" "${RESTOREY_HELPER_SERVICE:?}" "${RESTOREY_AGENT_PRODUCT_NAME:?}"
: "${TARGET_BUILD_DIR:?}" "${CONTENTS_FOLDER_PATH:?}"

dest_dir="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents"
mkdir -p "$dest_dir"
dest="${dest_dir}/${RESTOREY_AGENT_LABEL}.plist"

sed -e "s|@AGENT_LABEL@|${RESTOREY_AGENT_LABEL}|g" \
    -e "s|@HELPER_SERVICE@|${RESTOREY_HELPER_SERVICE}|g" \
    -e "s|@AGENT_PRODUCT@|${RESTOREY_AGENT_PRODUCT_NAME}|g" \
    "${SRCROOT}/LaunchAgents/agent.plist.template" > "$dest"
plutil -lint "$dest" >/dev/null
