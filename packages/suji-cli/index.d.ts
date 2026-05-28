export type SujiConfig = Record<string, unknown>;

export interface ConfigEnv {
  command: string;
  mode: string;
  cwd: string;
  configPath: string;
}

export type SujiConfigFactory<T extends SujiConfig = SujiConfig> = (env: ConfigEnv) => T | Promise<T>;

export declare function defineConfig<const T extends SujiConfig | SujiConfigFactory>(config: T): T;

export declare const CONFIG_FILE_NAMES: readonly string[];

export interface LoadConfigOptions {
  cwd?: string;
  config?: string;
  command?: string;
  mode?: string;
}

export declare function findConfigFile(cwd?: string): string | null;

export declare function loadConfig(options?: LoadConfigOptions): Promise<SujiConfig>;

export declare function configToJson(config: SujiConfig): string;
