export type SujiConfig = Record<string, unknown>;

export declare function defineConfig<const T extends SujiConfig>(config: T): T;
