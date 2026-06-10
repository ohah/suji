/**
 * @suji/plugin-terminal-node — PTY (pseudo-terminal) Plugin for Suji Node.js backends
 *
 * Spawns a shell through forkpty in the Zig `terminal` backend and streams its
 * output to the UI. Same wire contract as the other Suji plugins — route
 * through the `terminal` backend with the cmd embedded in the request JSON.
 *
 * start/write/resize/kill are request/response (getBridge().invoke). Output is
 * pushed from the backend via `suji.send("term:data", {id,data})` /
 * `suji.send("term:exit", {id})`; this SDK subscribes with `suji.on(channel, cb)`
 * and demultiplexes by session id.
 *
 * ```ts
 * const { terminal } = require('@suji/plugin-terminal-node');
 *
 * const id = await terminal.start({ cols: 80, rows: 24, cmd: 'claude' });
 * terminal.onData((sid, dataB64) => {
 *   if (sid === id) process.stdout.write(Buffer.from(dataB64, 'base64'));
 * });
 * terminal.onExit((sid) => { if (sid === id) console.log('exited'); });
 *
 * // forward keystrokes (data must be base64-encoded bytes)
 * await terminal.write(id, Buffer.from('ls\n').toString('base64'));
 * await terminal.resize(id, 120, 40);
 * await terminal.kill(id);
 * ```
 */
export interface StartOptions {
    /** Terminal width in columns (default 80). */
    cols?: number;
    /** Terminal height in rows (default 24). */
    rows?: number;
    /** Working directory for the spawned shell. */
    cwd?: string;
    /** Command to run (default: $SHELL or /bin/zsh). */
    cmd?: string;
}
export type DataListener = (id: number, dataBase64: string) => void;
export type ExitListener = (id: number) => void;
export declare const terminal: {
    /**
     * Spawn a shell in a new PTY. Resolves to a numeric session id used by
     * write/resize/kill and emitted alongside output in onData/onExit.
     */
    start(opts?: StartOptions): Promise<number>;
    /** Write input to the PTY. `data` must be a base64-encoded byte string. */
    write(id: number, data: string): Promise<void>;
    /** Resize the PTY (TIOCSWINSZ). */
    resize(id: number, cols: number, rows: number): Promise<void>;
    /** Terminate the session (SIGTERM + close). The session also emits onExit. */
    kill(id: number): Promise<void>;
    /**
     * Subscribe to PTY output. The callback receives `(id, dataBase64)` for every
     * session; filter by `id` if you manage multiple terminals. Returns an
     * unsubscribe function.
     */
    onData(cb: DataListener): () => void;
    /**
     * Subscribe to session-exit notifications (EOF / shell exit / read error).
     * Returns an unsubscribe function.
     */
    onExit(cb: ExitListener): () => void;
};
