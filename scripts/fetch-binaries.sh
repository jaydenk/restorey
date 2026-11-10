#!/usr/bin/env bash
# Download the pinned upstream restic and rest-server releases (darwin_arm64) into vendor/,
# verifying each against the SHA256SUMS published with its release. No Homebrew binaries.
set -euo pipefail
cd "$(dirname "$0")/.."

RESTIC_VERSION="0.19.1"
REST_SERVER_VERSION="0.14.0"
VENDOR="vendor"
mkdir -p "$VENDOR"

# download_verified <release base url> <asset> <label>: fetches the asset and checks it
# against the release's SHA256SUMS. Removes the asset and exits on a mismatch.
download_verified() {
  local base_url="$1" asset="$2" sums="$VENDOR/SHA256SUMS.$3"
  curl -fsSL -o "$VENDOR/$asset" "$base_url/$asset"
  curl -fsSL -o "$sums" "$base_url/SHA256SUMS"
  local expected actual
  expected=$(awk -v a="$asset" '$2 == a {print $1}' "$sums")
  actual=$(shasum -a 256 "$VENDOR/$asset" | awk '{print $1}')
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    echo "error: checksum mismatch for $asset (expected '$expected', got '$actual')" >&2
    rm -f "${VENDOR:?}/${asset:?}"
    exit 1
  fi
  echo "checksum OK: $asset ($actual)"
}

# restic ships as a bare bzip2-compressed executable.
if [[ -x "$VENDOR/restic" ]] && [[ "$("$VENDOR/restic" version)" == "restic ${RESTIC_VERSION} "* ]]; then
  echo "restic ${RESTIC_VERSION} already present"
else
  asset="restic_${RESTIC_VERSION}_darwin_arm64.bz2"
  download_verified "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}" "$asset" restic
  bunzip2 -c "$VENDOR/$asset" > "$VENDOR/restic"
  chmod +x "$VENDOR/restic"
  rm -f "${VENDOR:?}/${asset:?}"
fi
"$VENDOR/restic" version

# rest-server ships as a tar.gz holding a directory with the executable inside.
if [[ -x "$VENDOR/rest-server" ]] && [[ "$("$VENDOR/rest-server" --version)" == *"${REST_SERVER_VERSION}"* ]]; then
  echo "rest-server ${REST_SERVER_VERSION} already present"
else
  asset="rest-server_${REST_SERVER_VERSION}_darwin_arm64.tar.gz"
  download_verified "https://github.com/restic/rest-server/releases/download/v${REST_SERVER_VERSION}" "$asset" rest-server
  extract_dir=$(mktemp -d)
  tar -xzf "$VENDOR/$asset" -C "$extract_dir"
  binary=$(find "$extract_dir" -type f -name rest-server | head -1)
  [[ -n "$binary" ]] || { echo "error: no rest-server executable in $asset" >&2; exit 1; }
  cp "$binary" "$VENDOR/rest-server"
  chmod +x "$VENDOR/rest-server"
  rm -f "${VENDOR:?}/${asset:?}"
fi
"$VENDOR/rest-server" --version
