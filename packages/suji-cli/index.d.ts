export interface ConfigEnv {
  command: string;
  mode: string;
  cwd: string;
  configPath: string;
}

/** Code-signing mode (matches the `--sign` CLI flag). */
export type SigningMode = "adhoc" | "identity" | "none";

/** Per-platform build overrides (folded for the current OS at load time). */
export interface PlatformBuild {
  sign?: SigningMode;
  identity?: string;
  notarize?: boolean;
  dmg?: boolean;
  sandbox?: boolean;
  entitlements?: string;
}

/**
 * Build configuration + lifecycle hooks. Hooks are functions (programmatic — JSON
 * cannot express them); they are stripped from the resolved config and re-invoked by
 * the CLI at the matching lifecycle point. Per-platform overrides (mac/win/linux) are
 * folded over the top-level fields for the current OS.
 */
export interface BuildConfig extends PlatformBuild {
  beforeBuild?: (env: ConfigEnv) => void | Promise<void>;
  afterBuild?: (env: ConfigEnv) => void | Promise<void>;
  beforeDev?: (env: ConfigEnv) => void | Promise<void>;
  mac?: PlatformBuild;
  win?: PlatformBuild;
  linux?: PlatformBuild;
}

/** Dev server options. */
export interface DevConfig {
  /** Folds into `frontend.dev_url`. */
  devUrl?: string;
  /** Extra env vars injected when spawning the frontend dev server. */
  env?: Record<string, string>;
}

/**
 * Suji project config. Known fields are typed for autocomplete; the index signature
 * keeps it open for fields the Zig core consumes (app/windows/backend/frontend/fs/…).
 */
export interface SujiConfig {
  app?: Record<string, unknown>;
  /** Single-window shorthand — normalized to `windows: [window]`. */
  window?: Record<string, unknown>;
  windows?: Record<string, unknown>[];
  backend?: Record<string, unknown>;
  backends?: Record<string, unknown>[];
  frontend?: Record<string, unknown>;
  plugins?: unknown[];
  build?: BuildConfig;
  dev?: DevConfig;
  [key: string]: unknown;
}

export type SujiConfigFactory<T extends SujiConfig = SujiConfig> = (env: ConfigEnv) => T | Promise<T>;

export declare function defineConfig<const T extends SujiConfig | SujiConfigFactory>(config: T): T;

export declare const CONFIG_FILE_NAMES: readonly string[];

export interface LoadConfigOptions {
  cwd?: string;
  config?: string;
  command?: string;
  mode?: string;
  /** Run a single build lifecycle hook (beforeBuild/afterBuild/beforeDev) instead of resolving. */
  hook?: string;
}

export declare function findConfigFile(cwd?: string): string | null;

export declare function loadConfig(options?: LoadConfigOptions): Promise<SujiConfig>;

/** Run a build lifecycle hook (config.build.<hook>). Used by the CLI; no stdout. */
export declare function runHook(options?: LoadConfigOptions): Promise<void>;

export declare function configToJson(config: SujiConfig): string;
