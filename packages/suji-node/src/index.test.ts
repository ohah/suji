import { describe, it, expect, beforeEach, mock } from 'bun:test';

// Bridge 구조 — index.ts의 SujiBridge와 일치하는 mock.
type HandlerEntry = (data: string, event: any) => string;

let registered: Record<string, HandlerEntry> = {};
const bridge = {
  handle: mock((ch: string, fn: HandlerEntry) => { registered[ch] = fn; }),
  invoke: mock(() => Promise.resolve('{}')),
  invokeSync: mock(() => '{}'),
  send: mock(() => {}),
  sendTo: mock(() => {}),
  on: mock(() => 1),
  off: mock(() => {}),
  register: mock(() => {}),
  quit: mock(() => {}),
  platform: mock(() => 'macos'),
};

(globalThis as any).suji = bridge;

// bridge가 globalThis에 세팅된 뒤에 import
import { handle, invoke, invokeSync, send, sendTo, menu, fs as sujiFs, globalShortcut, screen, desktopCapturer, powerSaveBlocker, safeStorage, app, shell, webRequest, crashReporter, autoUpdater, type InvokeEvent } from './index';

beforeEach(() => {
  registered = {};
  for (const key of Object.keys(bridge) as (keyof typeof bridge)[]) {
    (bridge[key] as any).mockClear?.();
  }
});

describe('handle — 1-arity (기존 호환)', () => {
  it('파싱된 data를 단일 인자로 받는다', () => {
    const h = mock((_d: any) => ({ ok: true }));
    handle('ping', h);
    const result = registered['ping']('{"cmd":"ping"}', { window: { id: 0, name: null, url: null, is_main_frame: null } });
    expect(h).toHaveBeenCalledTimes(1);
    expect(h.mock.calls[0][0]).toEqual({ cmd: 'ping' });
    expect(result).toBe('{"ok":true}');
  });

  it('문자열 반환은 그대로 전달 (JSON.stringify 건너뜀)', () => {
    handle('ping', () => 'raw-string');
    expect(registered['ping']('{}', { window: { id: 0, name: null, url: null, is_main_frame: null } })).toBe('raw-string');
  });
});

describe('handle — 2-arity (InvokeEvent)', () => {
  it('event를 두 번째 인자로 받는다', () => {
    let captured: InvokeEvent | null = null;
    handle('save', (_data, event) => {
      captured = event;
      return { ok: true };
    });

    const ev = { window: { id: 7, name: 'settings', url: 'http://localhost:5173/settings', is_main_frame: null } };
    registered['save']('{"cmd":"save","__window":7,"__window_name":"settings","__window_url":"http://localhost:5173/settings"}', ev);

    expect(captured).toEqual(ev);
  });

  it('1-arity handler는 event를 받지 않는다 (handler.length === 1 분기)', () => {
    const h = mock((_d: any) => 'ok');
    handle('ping', h);
    registered['ping']('{}', { window: { id: 9, name: 'x', url: null, is_main_frame: null } });
    // 1-arity — 두 번째 인자 생략
    expect(h.mock.calls[0].length).toBe(1);
  });
});

describe('invoke / invokeSync', () => {
  it('invoke serializes request and parses JSON response', async () => {
    bridge.invoke.mockResolvedValueOnce('{"ok":true}');
    const result = await invoke<{ ok: boolean }>('zig', { cmd: 'ping' });
    expect(result).toEqual({ ok: true });
    expect(bridge.invoke).toHaveBeenCalledWith('zig', '{"cmd":"ping"}');
  });

  it('invokeSync serializes request and returns raw string when response is not JSON', () => {
    bridge.invokeSync.mockReturnValueOnce('raw-response');
    const result = invokeSync<string>('zig', { cmd: 'raw' });
    expect(result).toBe('raw-response');
    expect(bridge.invokeSync).toHaveBeenCalledWith('zig', '{"cmd":"raw"}');
  });
});

describe('send / sendTo', () => {
  it('send는 bridge.send(channel, JSON)로 전달', () => {
    send('event', { a: 1 });
    expect(bridge.send).toHaveBeenCalledWith('event', '{"a":1}');
  });

  it('sendTo는 windowId + JSON으로 bridge.sendTo 호출', () => {
    sendTo(3, 'toast', { text: 'saved' });
    expect(bridge.sendTo).toHaveBeenCalledWith(3, 'toast', '{"text":"saved"}');
  });

  it('sendTo는 data 생략 시 빈 객체 JSON', () => {
    sendTo(5, 'ping');
    expect(bridge.sendTo).toHaveBeenCalledWith(5, 'ping', '{}');
  });

  it('sendTo는 bridge에 필드가 없으면 silent no-op (구버전 core 호환)', () => {
    const savedSendTo = bridge.sendTo;
    (bridge as any).sendTo = undefined;
    expect(() => sendTo(1, 'x', {})).not.toThrow();
    bridge.sendTo = savedSendTo;
  });
});

describe('menu', () => {
  it('setApplicationMenu invokes __core__ with items', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    const ok = await menu.setApplicationMenu([
      { label: 'Tools', submenu: [{ label: 'Run', click: 'run' }, { type: 'checkbox', label: 'Flag', click: 'flag', checked: true }] },
    ]);
    expect(ok).toBe(true);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"menu_set_application_menu","items":[{"label":"Tools","submenu":[{"label":"Run","click":"run"},{"type":"checkbox","label":"Flag","click":"flag","checked":true}]}]}');
  });

  it('resetApplicationMenu invokes __core__', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    await menu.resetApplicationMenu();
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"menu_reset_application_menu"}');
  });
});

describe('fs', () => {
  it('readFile invokes __core__ and returns text', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true,"text":"hello"}');
    const text = await sujiFs.readFile('/tmp/a.txt');
    expect(text).toBe('hello');
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"fs_read_file","path":"/tmp/a.txt"}');
  });

  it('writeFile / stat / mkdir / readdir invoke __core__', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await sujiFs.writeFile('/tmp/a.txt', 'hello\nworld')).toBe(true);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"fs_write_file","path":"/tmp/a.txt","text":"hello\\nworld"}');

    bridge.invoke.mockResolvedValueOnce('{"success":true,"type":"file","size":5,"mtime":1700000000000}');
    const st = await sujiFs.stat('/tmp/a.txt');
    expect(st.type).toBe('file');
    expect(st.size).toBe(5);
    expect(st.mtime).toBe(1700000000000);
    expect(String(st.mtime).length).toBeLessThanOrEqual(13);

    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await sujiFs.mkdir('/tmp/dir', { recursive: true })).toBe(true);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"fs_mkdir","path":"/tmp/dir","recursive":true}');

    bridge.invoke.mockResolvedValueOnce('{"success":true,"entries":[{"name":"a.txt","type":"file"}]}');
    expect(await sujiFs.readdir('/tmp')).toEqual([{ name: 'a.txt', type: 'file' }]);

    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await sujiFs.rm('/tmp/x', { recursive: true, force: true })).toBe(true);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"fs_rm","path":"/tmp/x","recursive":true,"force":true}');
  });

  it('rm throws on failure', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":false,"error":"not_found"}');
    await expect(sujiFs.rm('/tmp/x')).rejects.toThrow('not_found');
  });

  it('stat throws on failure', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":false,"error":"not_found"}');
    await expect(sujiFs.stat('/missing')).rejects.toThrow('not_found');
  });
});

describe('globalShortcut', () => {
  it('register / unregister / unregisterAll / isRegistered invoke __core__', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await globalShortcut.register('Cmd+Shift+K', 'openSettings')).toBe(true);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"global_shortcut_register","accelerator":"Cmd+Shift+K","click":"openSettings"}');

    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await globalShortcut.unregister('Cmd+Shift+K')).toBe(true);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"global_shortcut_unregister","accelerator":"Cmd+Shift+K"}');

    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await globalShortcut.unregisterAll()).toBe(true);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"global_shortcut_unregister_all"}');

    bridge.invoke.mockResolvedValueOnce('{"registered":true}');
    expect(await globalShortcut.isRegistered('Cmd+Q')).toBe(true);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"global_shortcut_is_registered","accelerator":"Cmd+Q"}');
  });

  it('register returns false when success:false', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":false,"error":"parse_failed"}');
    expect(await globalShortcut.register('X', 'y')).toBe(false);
  });

  it('register escapes JSON-special chars in accelerator/click', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    await globalShortcut.register('Cmd+"한글"', 'click\nwith\\ctrl');
    expect(bridge.invoke).toHaveBeenCalledWith(
      '__core__',
      JSON.stringify({
        cmd: 'global_shortcut_register',
        accelerator: 'Cmd+"한글"',
        click: 'click\nwith\\ctrl',
      }),
    );
  });
});

describe('shell.trashItem', () => {
  it('sends shell_trash_item with path + maps success', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await shell.trashItem('/tmp/x')).toBe(true);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"shell_trash_item","path":"/tmp/x"}');
  });

  it('returns false when success:false', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":false}');
    expect(await shell.trashItem('/missing')).toBe(false);
  });
});

describe('webRequest', () => {
  it('setBlockedUrls sends patterns + returns count', async () => {
    bridge.invoke.mockResolvedValueOnce('{"count":1}');
    expect(await webRequest.setBlockedUrls(['https://x/*'])).toBe(1);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"web_request_set_blocked_urls","patterns":["https://x/*"]}');
  });

  it('setBlockedUrls empty list', async () => {
    bridge.invoke.mockResolvedValueOnce('{"count":0}');
    expect(await webRequest.setBlockedUrls([])).toBe(0);
  });
});

describe('screen', () => {
  it('getAllDisplays invokes + unwraps displays', async () => {
    bridge.invoke.mockResolvedValueOnce('{"displays":[{"index":0,"isPrimary":true,"x":0,"y":0,"width":1920,"height":1080,"visibleX":0,"visibleY":0,"visibleWidth":1920,"visibleHeight":1055,"scaleFactor":2}]}');
    const r = await screen.getAllDisplays();
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"screen_get_all_displays"}');
    expect(r.length).toBe(1);
    expect(r[0].isPrimary).toBe(true);
  });
});

describe('desktopCapturer', () => {
  it('getSources invokes + unwraps sources', async () => {
    bridge.invoke.mockResolvedValueOnce('{"sources":[{"id":"screen:1:0","type":"screen"}]}');
    const r = await desktopCapturer.getSources({ types: ['screen'] });
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"desktop_capturer_get_sources","types":"screen"}');
    expect(r).toEqual([{ id: 'screen:1:0', type: 'screen' }]);
  });

  it('captureThumbnail sends sourceId/path + maps success', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":false}');
    expect(await desktopCapturer.captureThumbnail('bad-source', '/tmp/thumb.png')).toBe(false);
    expect(bridge.invoke).toHaveBeenCalledWith(
      '__core__',
      '{"cmd":"desktop_capturer_capture_thumbnail","sourceId":"bad-source","path":"/tmp/thumb.png"}',
    );
  });
});

describe('crashReporter', () => {
  it('start sends options and maps success', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await crashReporter.start({ uploadToServer: false, extra: { suite: 'unit' } })).toBe(true);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"crash_reporter_start","uploadToServer":false,"extra":{"suite":"unit"}}');
  });

  it('start maps core validation failure to false', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":false,"error":"submitURL_required"}');
    expect(await crashReporter.start({ uploadToServer: true })).toBe(false);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"crash_reporter_start","uploadToServer":true}');
  });

  it('parameters and upload flag wrappers unwrap core responses', async () => {
    bridge.invoke.mockResolvedValueOnce('{"parameters":{"suite":"unit"}}');
    expect(await crashReporter.getParameters()).toEqual({ suite: 'unit' });

    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await crashReporter.addExtraParameter('mode', 'test')).toBe(true);

    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await crashReporter.removeExtraParameter('mode')).toBe(true);

    bridge.invoke.mockResolvedValueOnce('{"uploadToServer":false}');
    expect(await crashReporter.getUploadToServer()).toBe(false);

    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await crashReporter.setUploadToServer(false)).toBe(true);
  });

  it('report wrappers return array/null', async () => {
    bridge.invoke.mockResolvedValueOnce('{"reports":[]}');
    expect(await crashReporter.getUploadedReports()).toEqual([]);

    bridge.invoke.mockResolvedValueOnce('{"report":null}');
    expect(await crashReporter.getLastCrashReport()).toBeNull();
  });
});

describe('autoUpdater', () => {
  it('checkForUpdates sends manifest fields and returns result', async () => {
    bridge.invoke.mockResolvedValueOnce('{"updateAvailable":true,"currentVersion":"1.0.0","version":"1.1.0","url":"https://example.test/app.zip","sha256":"","notes":"release notes","pubDate":"2026-05-25T00:00:00Z"}');
    const r = await autoUpdater.checkForUpdates(
      {
        version: '1.1.0',
        url: 'https://example.test/app.zip',
        notes: 'release notes',
        pubDate: '2026-05-25T00:00:00Z',
      },
      { currentVersion: '1.0.0' },
    );
    expect(r.updateAvailable).toBe(true);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"auto_updater_check_update","currentVersion":"1.0.0","latestVersion":"1.1.0","url":"https://example.test/app.zip","sha256":"","notes":"release notes","pubDate":"2026-05-25T00:00:00Z"}');
  });

  it('verifyFile sends path/hash and returns actual digest', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":false,"actualSha256":"abc"}');
    expect(await autoUpdater.verifyFile('/tmp/suji.zip', '0'.repeat(64))).toEqual({
      success: false,
      actualSha256: 'abc',
    });
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', JSON.stringify({
      cmd: 'auto_updater_verify_file',
      path: '/tmp/suji.zip',
      sha256: '0'.repeat(64),
    }));
  });

  it('downloadArtifact sends URL/path/hash and supports explicit sha override', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true,"path":"/tmp/suji.zip","sha256":"' + '2'.repeat(64) + '","size":12}');
    expect(await autoUpdater.downloadArtifact('https://example.test/suji.zip', '/tmp/suji.zip', {
      sha256: '2'.repeat(64),
    })).toEqual({
      success: true,
      path: '/tmp/suji.zip',
      sha256: '2'.repeat(64),
      size: 12,
    });
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', JSON.stringify({
      cmd: 'auto_updater_download_artifact',
      url: 'https://example.test/suji.zip',
      path: '/tmp/suji.zip',
      sha256: '2'.repeat(64),
    }));
  });

  it('prepareInstall sends artifact, stage and format policy', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true,"path":"/tmp/Suji.app","source":"/tmp/Suji.app","target":"/Applications/Suji.app","stageDir":"/tmp/suji-stage","format":"zip","action":"quitAndInstall","requiresQuitAndInstall":true}');
    expect(await autoUpdater.prepareInstall({
      success: true,
      path: '/tmp/suji.zip',
      sha256: '3'.repeat(64),
      size: 12,
    }, {
      target: '/Applications/Suji.app',
      stageDir: '/tmp/suji-stage',
      format: 'zip',
    })).toEqual({
      success: true,
      path: '/tmp/Suji.app',
      source: '/tmp/Suji.app',
      target: '/Applications/Suji.app',
      stageDir: '/tmp/suji-stage',
      format: 'zip',
      action: 'quitAndInstall',
      requiresQuitAndInstall: true,
    });
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', JSON.stringify({
      cmd: 'auto_updater_prepare_install',
      path: '/tmp/suji.zip',
      target: '/Applications/Suji.app',
      stageDir: '/tmp/suji-stage',
      format: 'zip',
      sha256: '3'.repeat(64),
    }));
  });

  it('quitAndInstall sends staged path, target, hash and relaunch policy', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true,"path":"/tmp/suji.zip","target":"/Applications/Suji.app","helperPath":"/tmp/suji.zip.quit-install.sh","relaunch":false}');
    expect(await autoUpdater.quitAndInstall({
      success: true,
      path: '/tmp/suji.zip',
      sha256: '3'.repeat(64),
      size: 12,
    }, {
      target: '/Applications/Suji.app',
      relaunch: false,
    })).toEqual({
      success: true,
      path: '/tmp/suji.zip',
      target: '/Applications/Suji.app',
      helperPath: '/tmp/suji.zip.quit-install.sh',
      relaunch: false,
    });
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', JSON.stringify({
      cmd: 'auto_updater_quit_and_install',
      path: '/tmp/suji.zip',
      target: '/Applications/Suji.app',
      sha256: '3'.repeat(64),
      relaunch: false,
      helperPath: '',
    }));
  });

  it('quitAndInstall reuses prepareInstall target when options.target is omitted', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true,"path":"/tmp/Suji.app","target":"/Applications/Suji.app","helperPath":"/tmp/Suji.app.quit-install.sh","relaunch":false}');
    await autoUpdater.quitAndInstall({
      success: true,
      path: '/tmp/Suji.app',
      source: '/tmp/Suji.app',
      target: '/Applications/Suji.app',
      stageDir: '/tmp/stage',
      format: 'zip',
      action: 'quitAndInstall',
      requiresQuitAndInstall: true,
    }, { relaunch: false });
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', JSON.stringify({
      cmd: 'auto_updater_quit_and_install',
      path: '/tmp/Suji.app',
      target: '/Applications/Suji.app',
      sha256: '',
      relaunch: false,
      helperPath: '',
    }));
  });
});

describe('powerSaveBlocker', () => {
  it('start sends type and returns id', async () => {
    bridge.invoke.mockResolvedValueOnce('{"id":7}');
    expect(await powerSaveBlocker.start('prevent_display_sleep')).toBe(7);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"power_save_blocker_start","type":"prevent_display_sleep"}');
  });

  it('stop sends id and maps success', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await powerSaveBlocker.stop(7)).toBe(true);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"power_save_blocker_stop","id":7}');
  });
});

describe('safeStorage', () => {
  it('setItem sends service/account/value', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await safeStorage.setItem('svc', 'acc', 'v')).toBe(true);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"safe_storage_set","service":"svc","account":"acc","value":"v"}');
  });

  it('getItem returns value', async () => {
    bridge.invoke.mockResolvedValueOnce('{"value":"secret"}');
    expect(await safeStorage.getItem('svc', 'acc')).toBe('secret');
  });

  it('deleteItem maps success', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await safeStorage.deleteItem('svc', 'acc')).toBe(true);
  });

  it('setItem escapes quote/backslash via JSON.stringify', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    await safeStorage.setItem('svc', 'acc', 'a"b\\c');
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', JSON.stringify({
      cmd: 'safe_storage_set', service: 'svc', account: 'acc', value: 'a"b\\c',
    }));
  });
});

describe('app', () => {
  it('getPath sends name and returns path', async () => {
    bridge.invoke.mockResolvedValueOnce('{"path":"/Users/foo/Documents"}');
    expect(await app.getPath('documents')).toBe('/Users/foo/Documents');
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"app_get_path","name":"documents"}');
  });

  it('requestUserAttention default critical=true', async () => {
    bridge.invoke.mockResolvedValueOnce('{"id":42}');
    expect(await app.requestUserAttention()).toBe(42);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"app_attention_request","critical":true}');
  });

  it('setBadgeCount/getBadgeCount route through app badge count core commands', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await app.setBadgeCount(7)).toBe(true);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"app_set_badge_count","count":7}');

    bridge.invoke.mockResolvedValueOnce('{"count":7}');
    expect(await app.getBadgeCount()).toBe(7);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"app_get_badge_count"}');
  });

  it('requestUserAttention informational', async () => {
    bridge.invoke.mockResolvedValueOnce('{"id":1}');
    await app.requestUserAttention(false);
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"app_attention_request","critical":false}');
  });

  it('cancelUserAttentionRequest maps success', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    expect(await app.cancelUserAttentionRequest(42)).toBe(true);
  });

  it('dock.setBadge sends text', async () => {
    bridge.invoke.mockResolvedValueOnce('{"success":true}');
    await app.dock.setBadge('99');
    expect(bridge.invoke).toHaveBeenCalledWith('__core__', '{"cmd":"dock_set_badge","text":"99"}');
  });

  it('dock.getBadge returns text', async () => {
    bridge.invoke.mockResolvedValueOnce('{"text":"9"}');
    expect(await app.dock.getBadge()).toBe('9');
  });
});
