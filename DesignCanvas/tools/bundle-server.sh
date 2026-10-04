#!/bin/zsh
# Put the designtool server inside the Mac app so no one has to point the app at a
# checkout's dist/index.js. Run by the DesignCanvasMac target's post-build script
# (project.yml); usable by hand as
#
#     DesignCanvas/tools/bundle-server.sh <destination dir>
#
# The result is <destination>/{package.json,dist,node_modules}: the compiled server plus
# its production dependencies from a hoisted install (no symlinks, so the copy is
# self-contained and codesign is happy). Node itself is not bundled; the app resolves it
# from the login shell (AppModel.resolveNodePath).
#
# Without pnpm the bundle cannot be built. A Debug build then warns and continues (the
# app falls back to a checkout's dist/index.js or the Settings picker, as before); a
# Release build fails, because a release without its server is broken.
set -euo pipefail

dest=${1:?destination directory}
here=${0:A:h}
server=$here/../server
stage=${STAGE_DIR:-${TMPDIR:-/tmp}/design-canvas-server-stage}
config=${CONFIGURATION:-Debug}

warn_or_fail() {
  if [[ $config == Release ]]; then
    echo "error: $1" >&2; exit 1
  fi
  echo "warning: $1 — the app will look for a checkout's dist/index.js instead" >&2
  exit 0
}

# Xcode's script phase does not run a login shell, so pnpm from Homebrew or corepack
# is not on PATH unless we put the usual places there.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/Library/pnpm:$HOME/.local/share/pnpm"
command -v pnpm >/dev/null || warn_or_fail "pnpm not found; the server was not bundled"

# 1. Compile the server if its sources are newer than dist (or dist is missing).
if [[ ! -f $server/dist/index.js ]] || [[ -n $(find "$server/src" -newer "$server/dist/index.js" -name '*.ts' -print -quit) ]]; then
  (cd "$server" && pnpm install --frozen-lockfile --silent && pnpm --silent build)
fi

# 2. Production dependencies, hoisted into a plain node_modules. Cached on the lockfile
#    so a rebuild that did not touch dependencies costs one hash comparison.
lock_hash=$(shasum "$server/pnpm-lock.yaml" | cut -c1-40)
if [[ ! -f $stage/.lock-hash ]] || [[ $(<"$stage/.lock-hash") != "$lock_hash" ]]; then
  rm -rf "$stage" && mkdir -p "$stage"
  cp "$server/package.json" "$server/pnpm-lock.yaml" "$stage/"
  (cd "$stage" && pnpm install --prod --frozen-lockfile --ignore-scripts --silent --config.node-linker=hoisted)
  rm -rf "$stage/node_modules/.bin" "$stage/node_modules/.modules.yaml" "$stage/node_modules/.pnpm-workspace-state-v1.json"
  echo "$lock_hash" > "$stage/.lock-hash"
fi

# 3. Assemble. dist is copied fresh each time; node_modules only when it changed.
mkdir -p "$dest"
cp "$server/package.json" "$dest/"
rm -rf "$dest/dist" && cp -R "$server/dist" "$dest/dist"
find "$dest/dist" \( -name '*.map' -o -name '*.d.ts' \) -delete
if [[ ! -f $dest/.lock-hash ]] || [[ $(<"$dest/.lock-hash") != "$lock_hash" ]]; then
  rm -rf "$dest/node_modules" && cp -R "$stage/node_modules" "$dest/node_modules"
  echo "$lock_hash" > "$dest/.lock-hash"
fi
echo "bundled designtool into $dest"
