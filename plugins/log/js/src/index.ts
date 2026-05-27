/**
 * @suji/plugin-log — Rotating file logger for Suji Renderer
 *
 * Levels: "trace" < "debug" < "info" (default) < "warn" < "error" < "off".
 *
 * ```ts
 * import { log } from '@suji/plugin-log';
 *
 * await log.info("started", { pid: 1234 });
 * await log.error("oops", { user: "yoon" });
 * await log.setLevel("warn");
 * const tail = await log.read(50);
 * ```
 */

interface SujiBridge {
  invoke(channel: string, data?: Record<string, unknown>): Promise<any>;
}

function getBridge(): SujiBridge {
  const bridge = (window as any).__suji__;
  if (!bridge) throw new Error("Suji bridge not available.");
  return bridge;
}

export type LogLevel = "trace" | "debug" | "info" | "warn" | "error" | "off";

export interface LogEntry {
  ts: number;
  level: LogLevel;
  message: string;
  context?: Record<string, unknown>;
}

async function call(channel: string, data: Record<string, unknown>): Promise<any> {
  const resp = await getBridge().invoke(channel, data);
  if (resp?.error) throw new Error(`log: ${resp.error}`);
  return resp?.result ?? resp;
}

async function writeAt(level: LogLevel, message: string, context?: Record<string, unknown>): Promise<void> {
  await call("log:write", context !== undefined ? { level, message, context } : { level, message });
}

export const log = {
  trace: (message: string, context?: Record<string, unknown>) => writeAt("trace", message, context),
  debug: (message: string, context?: Record<string, unknown>) => writeAt("debug", message, context),
  info: (message: string, context?: Record<string, unknown>) => writeAt("info", message, context),
  warn: (message: string, context?: Record<string, unknown>) => writeAt("warn", message, context),
  error: (message: string, context?: Record<string, unknown>) => writeAt("error", message, context),

  async setLevel(level: LogLevel): Promise<void> {
    await call("log:set_level", { level });
  },

  async getLevel(): Promise<LogLevel> {
    const r = await call("log:get_level", {});
    return (r?.level ?? "info") as LogLevel;
  },

  /** 최근 N 줄(JSON Lines) 의 entries 반환. N 기본 100, 최대 10000. */
  async read(lines: number = 100): Promise<LogEntry[]> {
    const r = await call("log:read", { lines: String(lines) });
    return (r?.entries ?? []) as LogEntry[];
  },

  async setPath(path: string): Promise<string> {
    const r = await call("log:set_path", { path });
    return (r?.path ?? path) as string;
  },

  async getPath(): Promise<string> {
    const r = await call("log:get_path", {});
    return (r?.path ?? "") as string;
  },
};
