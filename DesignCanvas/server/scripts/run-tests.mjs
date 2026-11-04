import { readdirSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

function collectTests(dir, suffix = ".test.ts") {
  return readdirSync(dir, { withFileTypes: true })
    .flatMap((entry) => {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) return collectTests(path, suffix);
      return entry.isFile() && entry.name.endsWith(suffix) ? [path] : [];
    })
    .sort();
}

// The Claude Code mod is plain JavaScript with no package of its own; its tests
// run here so one command covers both halves of the daemon-to-session hop.
const files = [...collectTests("src"), ...collectTests("../mod/test", ".test.mjs")];
if (files.length === 0) {
  console.error("No test files found under src");
  process.exit(1);
}

const result = spawnSync(process.execPath, ["--import", "tsx", "--test", ...process.argv.slice(2), ...files], {
  stdio: "inherit",
});

process.exit(result.status ?? 1);
