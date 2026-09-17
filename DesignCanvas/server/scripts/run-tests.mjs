import { readdirSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

function collectTests(dir) {
  return readdirSync(dir, { withFileTypes: true })
    .flatMap((entry) => {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) return collectTests(path);
      return entry.isFile() && entry.name.endsWith(".test.ts") ? [path] : [];
    })
    .sort();
}

const files = collectTests("src");
if (files.length === 0) {
  console.error("No test files found under src");
  process.exit(1);
}

const result = spawnSync(process.execPath, ["--import", "tsx", "--test", ...process.argv.slice(2), ...files], {
  stdio: "inherit",
});

process.exit(result.status ?? 1);
