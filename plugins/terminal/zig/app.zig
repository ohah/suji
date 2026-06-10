//! @suji/plugin-terminal — PTY(의사 터미널) 백엔드.
//!
//! forkpty 로 셸을 spawn 하고, master fd 출력을 read 스레드가 읽어 base64 로
//! 인코딩한 뒤 `suji.send("term:data", {id,data})` 로 UI 에 push 한다. 입력/리사이즈/
//! 종료는 req/res 핸들러(term:write / term:resize / term:kill). qa-test-tool 의
//! xterm.js 탭이 이 플러그인을 써서 앱 안에서 `claude` 같은 인터랙티브 CLI 를 실행.
//!
//! 채널:
//!   term:start   {cols,rows,cwd?,shell?} → {id}       (read 스레드 시작)
//!   term:write   {id, data(base64)}     → {ok:true}   (master fd write)
//!   term:resize  {id, cols, rows}       → {ok:true}   (ioctl TIOCSWINSZ)
//!   term:kill    {id}                   → {ok:true}   (SIGTERM + close)
//!
//! push(서버→UI):
//!   term:data    {id, data(base64)}                   (master fd → read 스레드)
//!   term:exit    {id}                                 (EOF/read 에러)
//!
//! 플랫폼: POSIX(macOS+linux)만. forkpty/ioctl 은 libc(macOS=libSystem,
//! linux=libutil). Windows 는 ConPTY(CreatePseudoConsole) 가 필요해 1차 미지원 —
//! 모든 핸들러가 "unsupported_platform" 반환(conpty TODO).

const std = @import("std");
const builtin = @import("builtin");
const suji = @import("suji");

const is_posix = builtin.os.tag == .macos or builtin.os.tag == .linux;

// ============================================
// C 바인딩 — forkpty/ioctl/execvp/kill 등 POSIX PTY 경계.
//   macOS: <util.h> 에 forkpty. linux: <pty.h> 에 forkpty(-lutil).
//   ioctl TIOCSWINSZ + winsize 는 <sys/ioctl.h>/<termios.h>.
// non-POSIX 빌드에선 @cImport 자체를 건너뛴다(헤더 부재 회피).
// ============================================
const c = if (is_posix) @cImport({
    if (builtin.os.tag == .macos) {
        @cInclude("util.h"); // forkpty (macOS)
    } else {
        @cInclude("pty.h"); // forkpty (linux, -lutil)
    }
    @cInclude("sys/ioctl.h"); // ioctl, TIOCSWINSZ, struct winsize
    @cInclude("termios.h");
    @cInclude("unistd.h"); // execvp, chdir, read, write, close, _exit
    @cInclude("signal.h"); // kill, SIGTERM
    @cInclude("stdlib.h"); // getenv
    @cInclude("string.h");
}) else struct {};

pub const app = suji.app()
    .named("terminal")
    .handle("term:start", start)
    .handle("term:write", write)
    .handle("term:resize", resize)
    .handle("term:kill", kill);

var gpa: std.heap.DebugAllocator(.{}) = .init;
const alloc = gpa.allocator();

// ============================================
// 세션 레지스트리 (sessionId → Session, 글로벌 뮤텍스)
// ============================================
// sqlite/state 플러그인과 동형의 단일 뮤텍스 직렬화. read 스레드는 Session 을
// *포인터*로 잡고, 종료 시 closed 플래그를 보고 정리한다. Session 은 heap 할당
// 으로 read 스레드 lifetime 동안 안정적인 주소를 보장(맵 rehash 와 무관).

const READ_BUF = 16 * 1024;

const Session = struct {
    id: u32,
    master_fd: c_int,
    pid: c.pid_t,
    /// kill 요청 플래그 — read 스레드가 보고 정리. atomic store/load 로 race-free.
    closed: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
};

const Registry = struct {
    map: std.AutoHashMap(u32, *Session) = std.AutoHashMap(u32, *Session).init(alloc),
    mutex: std.Io.Mutex = .init,
    next_id: u32 = 1,
};
var reg: Registry = .{};

fn pluginIo() std.Io {
    return suji.io();
}

// ============================================
// JSON 헬퍼
// ============================================

/// base64 alphabet(+/=) 과 영숫자만 들어가므로 이스케이프 불필요 — 그대로 emit.
/// (sqlite appendJsonString 와 달리 입력 도메인이 좁아 escape 생략.)
fn emitData(id: u32, raw: []const u8) void {
    const enc = std.base64.standard.Encoder;
    const b64_len = enc.calcSize(raw.len);
    // {"id":4294967295,"data":""} = 27 + b64. 넉넉히 64 여유.
    const total = b64_len + 64;
    const buf = alloc.alloc(u8, total) catch return;
    defer alloc.free(buf);

    const prefix = std.fmt.bufPrint(buf, "{{\"id\":{d},\"data\":\"", .{id}) catch return;
    var n = prefix.len;
    const encoded = enc.encode(buf[n .. n + b64_len], raw);
    n += encoded.len;
    if (n + 2 > buf.len) return;
    buf[n] = '"';
    buf[n + 1] = '}';
    n += 2;
    suji.send("term:data", buf[0..n]);
}

fn emitExit(id: u32) void {
    var buf: [48]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{id}) catch return;
    suji.send("term:exit", json);
}

// ============================================
// read 스레드 — master fd 를 EOF/에러까지 read → term:data emit.
// 종료(EOF/에러/closed 플래그) 시 term:exit emit 후 Session 정리.
// ============================================

fn readLoop(sess: *Session) void {
    var buf: [READ_BUF]u8 = undefined;
    while (true) {
        if (sess.closed.load(.acquire)) break;
        const n = c.read(sess.master_fd, &buf, buf.len);
        if (n > 0) {
            emitData(sess.id, buf[0..@intCast(n)]);
            continue;
        }
        // n == 0: EOF (셸 종료). n < 0: 에러(EIO = PTY slave 닫힘 = 종료).
        // EINTR 면 재시도, 그 외는 종료.
        if (n < 0) {
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
        }
        break;
    }

    // kill 경유가 아니면(자연 종료) 여기서 exit emit + 정리. kill 경유면 kill 이
    // 이미 맵에서 제거했으므로 finishSelf 가 중복 제거를 no-op 으로 흡수.
    const killed = sess.closed.load(.acquire);
    if (!killed) emitExit(sess.id);
    finishSelf(sess, !killed);
}

/// read 스레드가 자기 자신을 정리 — fd 의 단일 소유자라 항상 여기서 close.
/// natural=true(자연 종료) 면 맵에서도 제거. natural=false(kill 경유) 면 kill
/// 핸들러가 이미 맵에서 뺐으므로 close + reap + free 만.
fn finishSelf(sess: *Session, natural: bool) void {
    if (natural) {
        reg.mutex.lockUncancelable(pluginIo());
        _ = reg.map.remove(sess.id);
        reg.mutex.unlock(pluginIo());
    }
    // master_fd 는 read 스레드 전용 소유 — close 도 여기서(다른 스레드 close 와
    // 경쟁하지 않으므로 macOS close-vs-read hang 회피).
    _ = c.close(sess.master_fd);
    // 좀비 방지 — 자식 reap. kill 경유든 자연 종료든 자식은 이미 죽었거나 곧 죽음.
    var status: c_int = 0;
    _ = c.waitpid(sess.pid, &status, 0);
    alloc.destroy(sess);
}

// ============================================
// 핸들러
// ============================================

fn start(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    if (comptime !is_posix) return req.err("unsupported_platform");

    const cols: u16 = blk: {
        const v = req.int("cols") orelse 80;
        break :blk if (v > 0 and v <= 10000) @intCast(v) else 80;
    };
    const rows: u16 = blk: {
        const v = req.int("rows") orelse 24;
        break :blk if (v > 0 and v <= 10000) @intCast(v) else 24;
    };

    // 셸 기본값 = $SHELL or /bin/zsh. cwd 옵션.
    // ⚠️ 파라미터명은 `shell` — `cmd` 는 wire envelope 의 채널명("term:start")으로
    // 예약돼 있다. {"cmd":"term:start","cmd":"/bin/sh"} 처럼 두 번 들어가면 경량
    // JSON 파서가 첫 "cmd"(채널)를 집어 셸 path 가 가려진다. 그래서 셸 실행 파일은
    // 별도 키 `shell` 로 받는다.
    const shell: []const u8 = req.string("shell") orelse defaultShell();
    const cwd: ?[]const u8 = req.string("cwd");

    // null-종단 사본 (execvp/chdir 용). arena 라 핸들러 반환 시 해제되지만,
    // execvp 는 fork 직후 자식에서 즉시 호출되므로 fork 이전 부모 스택이 살아있는
    // 동안 유효. 자식은 부모 메모리 COW 복사라 fork 시점 값 그대로 본다.
    const cmd_z = req.arena.dupeZ(u8, shell) catch return req.err("alloc");
    const cwd_z: ?[:0]const u8 = if (cwd) |w| (req.arena.dupeZ(u8, w) catch return req.err("alloc")) else null;

    var ws: c.struct_winsize = .{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    var master_fd: c_int = -1;
    // forkpty: 부모는 master fd + 자식 pid, 자식은 slave 가 stdin/out/err 인 새 세션.
    const pid = c.forkpty(&master_fd, null, null, &ws);
    if (pid < 0) return req.err("forkpty failed");

    if (pid == 0) {
        // ===== 자식 =====
        if (cwd_z) |w| {
            if (c.chdir(w.ptr) != 0) {
                // chdir 실패는 치명적이지 않게 — 그냥 무시하고 셸 실행.
            }
        }
        // execvp(셸) — argv[0]=셸, argv[1]=null. 로그인 셸 표기는 1차 생략.
        // execvp 시그니처가 [*c]const [*c]u8 (mutable inner) 이라 const 캐스트.
        var argv = [2]?[*:0]const u8{ cmd_z.ptr, null };
        _ = c.execvp(cmd_z.ptr, @ptrCast(&argv));
        // execvp 가 돌아왔으면 실패 — 자식 즉시 종료(부모 read 가 EOF 로 감지).
        c._exit(127);
    }

    // ===== 부모 =====
    const sess = alloc.create(Session) catch {
        _ = c.close(master_fd);
        _ = c.kill(pid, c.SIGTERM);
        return req.err("alloc");
    };

    reg.mutex.lockUncancelable(pluginIo());
    const id = reg.next_id;
    reg.map.put(id, sess) catch {
        reg.mutex.unlock(pluginIo());
        alloc.destroy(sess);
        _ = c.close(master_fd);
        _ = c.kill(pid, c.SIGTERM);
        return req.err("registry full");
    };
    reg.next_id += 1;
    sess.* = .{ .id = id, .master_fd = master_fd, .pid = pid };
    reg.mutex.unlock(pluginIo());

    // read 스레드 시작 — master fd → term:data. 실패 시 롤백.
    sess.thread = std.Thread.spawn(.{}, readLoop, .{sess}) catch {
        reg.mutex.lockUncancelable(pluginIo());
        _ = reg.map.remove(id);
        reg.mutex.unlock(pluginIo());
        _ = c.close(master_fd);
        _ = c.kill(pid, c.SIGTERM);
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
        alloc.destroy(sess);
        return req.err("thread spawn failed");
    };
    // detach — read 스레드가 자기 정리(finishSelf)까지 책임지므로 join 불필요.
    sess.thread.?.detach();

    return req.okRaw(std.fmt.allocPrint(req.arena, "{{\"id\":{d}}}", .{id}) catch return req.err("format error"));
}

fn write(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    if (comptime !is_posix) return req.err("unsupported_platform");

    const id = sessionIdKey(req) orelse return req.err("invalid id");
    const data_b64 = req.string("data") orelse return req.err("missing data");

    // fd 를 잠금 안에서 스냅샷 — write 자체는 잠금 밖(blocking I/O 직렬화 방지).
    reg.mutex.lockUncancelable(pluginIo());
    const sess = reg.map.get(id);
    const fd: c_int = if (sess) |s| s.master_fd else -1;
    reg.mutex.unlock(pluginIo());
    if (sess == null) return req.err("invalid id");

    // base64 decode → master fd write.
    const dec = std.base64.standard.Decoder;
    const out_len = dec.calcSizeForSlice(data_b64) catch return req.err("invalid base64");
    const out = req.arena.alloc(u8, out_len) catch return req.err("alloc");
    dec.decode(out, data_b64) catch return req.err("invalid base64");

    var written: usize = 0;
    while (written < out.len) {
        const n = c.write(fd, out.ptr + written, out.len - written);
        if (n < 0) {
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            return req.err("write failed");
        }
        if (n == 0) break;
        written += @intCast(n);
    }
    return req.okRaw("{\"ok\":true}");
}

fn resize(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    if (comptime !is_posix) return req.err("unsupported_platform");

    const id = sessionIdKey(req) orelse return req.err("invalid id");
    const cols: u16 = blk: {
        const v = req.int("cols") orelse return req.err("missing cols");
        break :blk if (v > 0 and v <= 10000) @intCast(v) else return req.err("invalid cols");
    };
    const rows: u16 = blk: {
        const v = req.int("rows") orelse return req.err("missing rows");
        break :blk if (v > 0 and v <= 10000) @intCast(v) else return req.err("invalid rows");
    };

    reg.mutex.lockUncancelable(pluginIo());
    const sess = reg.map.get(id);
    const fd: c_int = if (sess) |s| s.master_fd else -1;
    reg.mutex.unlock(pluginIo());
    if (sess == null) return req.err("invalid id");

    var ws: c.struct_winsize = .{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    if (c.ioctl(fd, c.TIOCSWINSZ, &ws) != 0) return req.err("resize failed");
    return req.okRaw("{\"ok\":true}");
}

fn kill(req: suji.Request, _: suji.InvokeEvent) suji.Response {
    if (comptime !is_posix) return req.err("unsupported_platform");

    const id = sessionIdKey(req) orelse return req.err("invalid id");

    // 맵에서 제거 + closed 플래그 set + SIGTERM. ⚠️ master_fd 는 여기서 close 하지
    // 않는다 — read 스레드가 같은 fd 에서 blocking read 중이라, 다른 스레드에서
    // close() 하면 macOS 는 read 가 끝날 때까지 close 를 막아 상호 hang 이 된다.
    // 대신 자식에 SIGTERM → slave 닫힘 → master read 가 EOF/EIO 로 깨어남 → read
    // 스레드가 closed 플래그 보고 루프 탈출 후 finishSelf 에서 fd close + reap + free.
    // (fd 의 단일 소유자 = read 스레드.)
    reg.mutex.lockUncancelable(pluginIo());
    const kv = reg.map.fetchRemove(id);
    reg.mutex.unlock(pluginIo());

    const sess = (kv orelse return req.err("invalid id")).value;
    sess.closed.store(true, .release);
    _ = c.kill(sess.pid, c.SIGTERM); // 자식 종료 → slave 닫힘 → master read 깨움

    return req.okRaw("{\"ok\":true}");
}

// ============================================
// 유틸
// ============================================

/// req "id" → 유효 u32 키. 누락/범위밖이면 null.
fn sessionIdKey(req: suji.Request) ?u32 {
    const id = req.int("id") orelse return null;
    if (id <= 0 or id > std.math.maxInt(u32)) return null;
    return @intCast(id);
}

/// 기본 셸 — $SHELL 환경변수, 없으면 /bin/zsh.
fn defaultShell() []const u8 {
    if (comptime is_posix) {
        const raw = c.getenv("SHELL");
        if (raw != null) {
            const s = std.mem.span(raw);
            if (s.len > 0) return s;
        }
    }
    return "/bin/zsh";
}

comptime {
    _ = suji.exportApp(app);
}
