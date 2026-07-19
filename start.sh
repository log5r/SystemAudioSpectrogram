#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="$ROOT_DIR/SystemAudioSpectrogram.xcodeproj"
SCHEME="SystemAudioSpectrogram"
CONFIGURATION="${CONFIGURATION:-Release}"
DESTINATION="platform=macOS,arch=$(uname -m)"
SHOULD_BUILD=0

find_app_path() {
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -showBuildSettings 2>/dev/null |
  awk -F ' = ' '
    /CODESIGNING_FOLDER_PATH = / { app_path = $2 }
    /BUILT_PRODUCTS_DIR = / { built_products_dir = $2 }
    /FULL_PRODUCT_NAME = / { full_product_name = $2 }
    END {
      if (app_path != "") {
        print app_path
      } else if (built_products_dir != "" && full_product_name != "") {
        print built_products_dir "/" full_product_name
      }
    }
  '
}

APP_PATH="$(find_app_path)"

if (($# > 0)) || [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  SHOULD_BUILD=1
fi

if ((SHOULD_BUILD)); then
  echo "Building $SCHEME ($CONFIGURATION)..."
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    build

  APP_PATH="$(find_app_path)"
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "error: built app was not found after building." >&2
  exit 1
fi

echo "Launching $APP_PATH..."
open -n "$APP_PATH"
