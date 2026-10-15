#!/bin/zsh
# Put the Design Canvas Claude Code mod inside the Mac app, next to the server, so Start
# session can load it with `claude --plugin-dir` and the "every session" option has a
# directory to point Claude Code at (spec/technical_doc-ClaudeMods.md, 2.1). Run by the
# DesignCanvasMac target's post-build script (project.yml); usable by hand as
#
#     DesignCanvas/tools/bundle-mod.sh <destination dir>
#
# The mod is plain JavaScript with no build step and no dependencies, so this is a copy
# of three files. Its tests (mod/test) and the type declarations Claude Code writes beside
# a mod it loads from a checkout (.claude-plugin/types) are left behind.
set -euo pipefail

dest=${1:?destination directory}
here=${0:A:h}
mod=$here/../mod

for file in .claude-plugin/plugin.json hooks/hooks.json hooks/register.js; do
  [[ -f $mod/$file ]] || { echo "error: $mod/$file is missing" >&2; exit 1; }
done

rm -rf "$dest"
mkdir -p "$dest/.claude-plugin" "$dest/hooks"
cp "$mod/.claude-plugin/plugin.json" "$dest/.claude-plugin/"
cp "$mod/hooks/hooks.json" "$mod/hooks/register.js" "$dest/hooks/"
echo "bundled the Design Canvas mod into $dest"
