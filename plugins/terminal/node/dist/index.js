"use strict";
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
Object.defineProperty(exports, "__esModule", { value: true });
exports.terminal = void 0;
function getBridge() {
    const bridge = globalThis.suji;
    if (!bridge) {
        throw new Error("@suji/plugin-terminal-node: bridge not available. This module must run inside a Suji app (libnode embedding).");
    }
    return bridge;
}
/** invoke("terminal", {cmd,...}) → parse, unwrap {from:"zig",result|error}. */
async function call(cmd, payload) {
    const raw = await getBridge().invoke("terminal", JSON.stringify({ cmd, ...payload }));
    let resp;
    try {
        resp = JSON.parse(raw);
    }
    catch {
        resp = {};
    }
    if (resp?.error)
        throw new Error(`terminal: ${resp.error}`);
    return resp?.result;
}
// ============================================
// Event demux — a single suji.on() subscription per channel fans out to all
// registered listeners. The bridge invokes every listener for every event, so
// the callback filters by its own channel and decodes the {id,data} payload.
// ============================================
const dataListeners = new Set();
const exitListeners = new Set();
let dataSubId = null;
let exitSubId = null;
function ensureDataSub() {
    if (dataSubId !== null)
        return;
    dataSubId = getBridge().on("term:data", (channel, data) => {
        if (channel !== "term:data")
            return; // bridge fans out all events to all listeners
        let payload;
        try {
            payload = JSON.parse(data);
        }
        catch {
            return;
        }
        if (typeof payload.id !== "number" || typeof payload.data !== "string")
            return;
        for (const cb of dataListeners) {
            try {
                cb(payload.id, payload.data);
            }
            catch {
                /* listener errors must not break the demux loop */
            }
        }
    });
}
function ensureExitSub() {
    if (exitSubId !== null)
        return;
    exitSubId = getBridge().on("term:exit", (channel, data) => {
        if (channel !== "term:exit")
            return;
        let payload;
        try {
            payload = JSON.parse(data);
        }
        catch {
            return;
        }
        if (typeof payload.id !== "number")
            return;
        for (const cb of exitListeners) {
            try {
                cb(payload.id);
            }
            catch {
                /* swallow */
            }
        }
    });
}
exports.terminal = {
    /**
     * Spawn a shell in a new PTY. Resolves to a numeric session id used by
     * write/resize/kill and emitted alongside output in onData/onExit.
     */
    async start(opts = {}) {
        const payload = {
            cols: opts.cols ?? 80,
            rows: opts.rows ?? 24,
        };
        if (opts.cwd !== undefined)
            payload.cwd = opts.cwd;
        // wire field is `shell`, not `cmd`: the request envelope reserves `cmd` for
        // the channel name ("term:start"), so the shell binary travels under `shell`.
        if (opts.cmd !== undefined)
            payload.shell = opts.cmd;
        const r = await call("term:start", payload);
        if (typeof r?.id !== "number") {
            throw new Error("terminal: malformed start response (no id)");
        }
        return r.id;
    },
    /** Write input to the PTY. `data` must be a base64-encoded byte string. */
    async write(id, data) {
        await call("term:write", { id, data });
    },
    /** Resize the PTY (TIOCSWINSZ). */
    async resize(id, cols, rows) {
        await call("term:resize", { id, cols, rows });
    },
    /** Terminate the session (SIGTERM + close). The session also emits onExit. */
    async kill(id) {
        await call("term:kill", { id });
    },
    /**
     * Subscribe to PTY output. The callback receives `(id, dataBase64)` for every
     * session; filter by `id` if you manage multiple terminals. Returns an
     * unsubscribe function.
     */
    onData(cb) {
        ensureDataSub();
        dataListeners.add(cb);
        return () => dataListeners.delete(cb);
    },
    /**
     * Subscribe to session-exit notifications (EOF / shell exit / read error).
     * Returns an unsubscribe function.
     */
    onExit(cb) {
        ensureExitSub();
        exitListeners.add(cb);
        return () => exitListeners.delete(cb);
    },
};
