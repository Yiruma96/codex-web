#!/usr/bin/env node

import {
  link,
  lstat,
  mkdir,
  readFile,
  readdir,
  realpath,
  rename,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import process from "node:process";

function parseArgs(argv) {
  const result = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value == null) {
      throw new Error("Usage: prepare-web-codex-home.mjs --source <path> --target <path>");
    }
    result.set(key.slice(2), value);
  }
  return result;
}

async function exists(filePath) {
  try {
    await lstat(filePath);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") {
      return false;
    }
    throw error;
  }
}

async function ensureDirectoryJunction(sourcePath, targetPath) {
  if (await exists(targetPath)) {
    const targetStat = await lstat(targetPath);
    if (!targetStat.isSymbolicLink()) {
      throw new Error(`Refusing to replace non-junction directory: ${targetPath}`);
    }
    const resolvedTarget = await realpath(targetPath);
    const resolvedSource = await realpath(sourcePath);
    if (path.normalize(resolvedTarget) !== path.normalize(resolvedSource)) {
      throw new Error(`Junction points to an unexpected target: ${targetPath}`);
    }
    return;
  }

  await symlink(sourcePath, targetPath, "junction");
}

async function ensureFileHardLink(sourcePath, targetPath) {
  if (await exists(targetPath)) {
    const [sourceStat, targetStat] = await Promise.all([
      stat(sourcePath),
      stat(targetPath),
    ]);
    if (sourceStat.dev === targetStat.dev && sourceStat.ino === targetStat.ino) {
      return;
    }
    await rm(targetPath, { force: true });
  }

  await link(sourcePath, targetPath);
}

function sanitizeGlobalState(globalState) {
  delete globalState["selected-remote-host-id"];
  delete globalState["active-remote-project-id"];
  delete globalState["remote-projects"];
  delete globalState["codex-managed-remote-connections"];
  delete globalState["remote-connection-analytics-id-by-host-id"];
  globalState["remote-connection-auto-connect-by-host-id"] = {};

  const persisted = globalState["electron-persisted-atom-state"];
  if (persisted && typeof persisted === "object" && !Array.isArray(persisted)) {
    persisted["last-used-continue-in-mode"] = "local";
  }

  return globalState;
}

async function writeSanitizedGlobalState(sourceHome, targetHome) {
  const sourcePath = path.join(sourceHome, ".codex-global-state.json");
  const targetPath = path.join(targetHome, ".codex-global-state.json");
  const backupPath = `${targetPath}.bak`;
  const temporaryPath = `${targetPath}.tmp-${process.pid}`;

  let globalState = {};
  if (await exists(sourcePath)) {
    globalState = JSON.parse(await readFile(sourcePath, "utf8"));
  }

  const serialized = JSON.stringify(sanitizeGlobalState(globalState));
  await writeFile(temporaryPath, serialized, "utf8");
  await rename(temporaryPath, targetPath);
  await writeFile(backupPath, serialized, "utf8");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const sourceHome = path.resolve(args.get("source") ?? "");
  const targetHome = path.resolve(args.get("target") ?? "");

  if (!sourceHome || !targetHome || sourceHome === targetHome) {
    throw new Error("Source and target Codex homes must be different absolute paths.");
  }
  if (path.dirname(sourceHome) !== path.dirname(targetHome)) {
    throw new Error("The Web Codex home must be beside the real Codex home so file hard links stay on one volume.");
  }

  await mkdir(targetHome, { recursive: true });
  const entries = await readdir(sourceHome, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.name.startsWith(".codex-global-state.json") || entry.name.startsWith("..codex-global-state.json")) {
      continue;
    }

    const sourcePath = path.join(sourceHome, entry.name);
    const targetPath = path.join(targetHome, entry.name);
    if (entry.isDirectory()) {
      await ensureDirectoryJunction(sourcePath, targetPath);
    } else if (entry.isFile()) {
      await ensureFileHardLink(sourcePath, targetPath);
    }
  }

  await writeSanitizedGlobalState(sourceHome, targetHome);
  process.stdout.write(`Prepared local-only Web Codex state at ${targetHome}.\n`);
}

await main();
