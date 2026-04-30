#!/usr/bin/env node
const { spawnSync } = require("node:child_process");
const { join } = require("node:path");

function platformPkg() {
  const { platform, arch } = process;
  if (platform === "darwin" && arch === "arm64") return "seetree-darwin-arm64";
  if (platform === "darwin" && arch === "x64") return "seetree-darwin-x64";
  if (platform === "linux" && arch === "arm64") return "seetree-linux-arm64-musl";
  if (platform === "linux" && arch === "x64") return "seetree-linux-x64-musl";
  console.error(`seetree: unsupported platform ${platform}-${arch}`);
  process.exit(1);
}

const pkg = platformPkg();
let binPath;
try {
  binPath = join(require.resolve(`${pkg}/package.json`), "..", "bin", "seetree");
} catch {
  console.error(`seetree: missing platform package ${pkg}`);
  console.error("reinstall with: npm i -g seetree");
  process.exit(1);
}

const result = spawnSync(binPath, process.argv.slice(2), { stdio: "inherit" });
if (result.signal) process.kill(process.pid, result.signal);
process.exit(result.status ?? 0);
