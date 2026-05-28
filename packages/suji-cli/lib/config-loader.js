import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { basename, extname, isAbsolute, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const CONFIG_FILE_NAMES = [
  "suji.config.ts",
  "suji.config.mts",
  "suji.config.cts",
  "suji.config.js",
  "suji.config.mjs",
  "suji.config.cjs",
  "suji.json",
];

export function defineConfig(config) {
  return config;
}

export function findConfigFile(cwd = process.cwd()) {
  const root = resolve(cwd);
  for (const name of CONFIG_FILE_NAMES) {
    const file = join(root, name);
    if (existsSync(file)) return file;
  }
  return null;
}

export async function loadConfig(options = {}) {
  const cwd = resolve(options.cwd ?? process.cwd());
  const configPath = resolveConfigPath(cwd, options.config);
  if (!configPath) {
    throw new Error(`Suji config not found in ${cwd}`);
  }

  const value = basename(configPath) === "suji.json"
    ? loadJsonConfig(configPath)
    : await loadCodeConfig(configPath, {
      command: options.command ?? "dev",
      mode: options.mode ?? process.env.NODE_ENV ?? "development",
      cwd,
    });

  assertConfigObject(value);
  return value;
}

export function configToJson(config) {
  assertConfigObject(config);
  return `${JSON.stringify(config, null, 2)}\n`;
}

function resolveConfigPath(cwd, config) {
  if (!config) return findConfigFile(cwd);
  const file = isAbsolute(config) ? config : resolve(cwd, config);
  if (!existsSync(file)) throw new Error(`Suji config not found: ${file}`);
  return file;
}

function loadJsonConfig(configPath) {
  try {
    return JSON.parse(readFileSync(configPath, "utf8"));
  } catch (error) {
    throw new Error(`Failed to parse ${configPath}: ${error.message}`);
  }
}

async function loadCodeConfig(configPath, context) {
  const module = await importConfigModule(configPath, context.cwd);
  const exported = resolveConfigExport(module);
  return typeof exported === "function"
    ? await exported({ ...context, configPath })
    : exported;
}

async function importConfigModule(configPath, cwd) {
  const extension = extname(configPath);
  try {
    return await import(pathToFileURL(configPath).href);
  } catch (error) {
    if (![".ts", ".mts", ".cts"].includes(extension) || !shouldUseTsFallback(error)) throw error;
    return await importTransformedTsConfig(configPath, cwd, error);
  }
}

function shouldUseTsFallback(error) {
  if (error?.code === "ERR_UNKNOWN_FILE_EXTENSION") return true;
  if (error?.code === "ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX") return true;
  if (error?.code === "ERR_MODULE_NOT_FOUND") return true;
  if (error?.code === "ERR_UNSUPPORTED_DIR_IMPORT") return true;
  return /Unknown file extension|unsupported TypeScript|strip-only mode/i.test(error?.message ?? "");
}

async function importTransformedTsConfig(configPath, cwd, cause) {
  let buildSync;
  try {
    ({ buildSync } = await import("esbuild"));
  } catch {
    throw new Error(
      `Node could not import ${configPath} directly, and esbuild is not installed for the fallback transform. Original error: ${cause.message}`,
    );
  }

  const source = readFileSync(configPath, "utf8");
  const cacheDir = join(cwd, ".suji", "cache", "config-loader");
  mkdirSync(cacheDir, { recursive: true });
  const hash = createHash("sha256")
    .update(configPath)
    .update("\0")
    .update(source)
    .update("\0")
    .update(String(Date.now()))
    .digest("hex")
    .slice(0, 16);
  const transformedPath = join(cacheDir, `${basename(configPath)}-${hash}.mjs`);
  buildSync({
    absWorkingDir: cwd,
    entryPoints: [configPath],
    outfile: transformedPath,
    bundle: true,
    platform: "node",
    format: "esm",
    target: "node18",
    packages: "external",
    sourcemap: "inline",
    logLevel: "silent",
  });
  return await import(pathToFileURL(transformedPath).href);
}

function resolveConfigExport(module) {
  const hasDefault = Object.prototype.hasOwnProperty.call(module, "default");
  const hasNamedConfig = Object.prototype.hasOwnProperty.call(module, "config");

  if (hasDefault && hasNamedConfig && module.default && typeof module.default === "object") {
    const keys = Object.keys(module.default);
    if (keys.length === 1 && module.default.config === module.config) return module.config;
  }
  if (hasDefault && module.default !== undefined) return module.default;
  if (hasNamedConfig) return module.config;
  return module;
}

function assertJsonValue(value, path = "$") {
  if (value === null) return;

  const kind = typeof value;
  if (kind === "string" || kind === "boolean") return;
  if (kind === "number") {
    if (!Number.isFinite(value)) throw new Error(`${path} must be a finite number`);
    return;
  }
  if (kind === "undefined") throw new Error(`${path} must not be undefined`);
  if (kind === "bigint") throw new Error(`${path} must not be a bigint`);
  if (kind === "function") throw new Error(`${path} must not be a function`);
  if (kind === "symbol") throw new Error(`${path} must not be a symbol`);

  if (Array.isArray(value)) {
    value.forEach((item, index) => assertJsonValue(item, `${path}[${index}]`));
    return;
  }

  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) {
    throw new Error(`${path} must be a plain JSON object`);
  }

  for (const [key, item] of Object.entries(value)) {
    assertJsonValue(item, `${path}.${key}`);
  }
}

function assertConfigObject(value) {
  assertJsonValue(value);
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("$ must be a plain JSON object");
  }
}
