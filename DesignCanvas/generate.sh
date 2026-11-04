#!/bin/zsh
# Regenerate DesignCanvas.xcodeproj. Reads DEVELOPMENT_TEAM from a .env next to
# this script, or from the one at the repo root, so personal signing config
# stays out of the repo:
#   echo "DEVELOPMENT_TEAM=YOURTEAMID" > .env
set -e
cd "$(dirname "$0")"
for env in .env ../.env; do
  if [[ -f $env ]]; then
    export $(grep -v '^#' $env | xargs)
    break
  fi
done
exec xcodegen generate
