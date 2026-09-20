import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

const required = [
  "dist/main/main.js",
  "dist/preload/preload.cjs",
  "dist/renderer/index.html"
];

const missing = required.filter((item) => !existsSync(path.resolve(item)));

if (missing.length > 0) {
  console.error("Missing build artifacts:");
  for (const item of missing) {
    console.error(`- ${item}`);
  }
  process.exit(1);
}

const textChecks = [
  {
    file: "dist/main/main.js",
    checks: [
      { label: "loads preload.cjs", pattern: /preload\.cjs/ },
      { label: "contextIsolation true", pattern: /contextIsolation:\s*true/ },
      { label: "sandbox true", pattern: /sandbox:\s*true/ },
      { label: "nodeIntegration false", pattern: /nodeIntegration:\s*false/ },
      { label: "webSecurity true", pattern: /webSecurity:\s*true/ }
    ]
  },
  {
    file: "dist/preload/preload.cjs",
    checks: [
      { label: "exposes window.acode", pattern: /exposeInMainWorld\(["']acode["']/ }
    ]
  }
];

const failedChecks = [];

for (const item of textChecks) {
  const absolutePath = path.resolve(item.file);
  const content = readFileSync(absolutePath, "utf8");

  for (const check of item.checks) {
    if (!check.pattern.test(content)) {
      failedChecks.push(`${item.file}: ${check.label}`);
    }
  }
}

if (failedChecks.length > 0) {
  console.error("Smoke check failed:");
  for (const item of failedChecks) {
    console.error(`- ${item}`);
  }
  process.exit(1);
}

console.log("Smoke check passed.");
