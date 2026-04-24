package suji

import "testing"

// 1 기능 1 테스트. core 주입 전 silent no-op 계약 검증.

func TestQuitNoopWithoutCore(t *testing.T) {
	// core 주입 안 된 상태에서 Quit 호출 — crash 없어야.
	Quit()
}

func TestPlatformReturnsUnknownWithoutCore(t *testing.T) {
	if got := Platform(); got != "unknown" {
		t.Fatalf("expected \"unknown\" before core injection, got %q", got)
	}
}

func TestPlatformConstants(t *testing.T) {
	if PlatformMacOS != "macos" {
		t.Errorf("PlatformMacOS = %q, want \"macos\"", PlatformMacOS)
	}
	if PlatformLinux != "linux" {
		t.Errorf("PlatformLinux = %q, want \"linux\"", PlatformLinux)
	}
	if PlatformWindows != "windows" {
		t.Errorf("PlatformWindows = %q, want \"windows\"", PlatformWindows)
	}
}

func TestOffNoopOnInvalidID(t *testing.T) {
	// 존재하지 않는 listener id에 Off — crash 없어야.
	Off(0)
	Off(99999)
}

func TestOnQueuesWhenCoreMissing(t *testing.T) {
	// core 주입 전 On() 호출은 pending 큐에 쌓임 + id 반환
	before := goListenerNextID
	id := On("test:event", func(_, _ string) {})
	if id == 0 {
		t.Fatal("expected non-zero id even when core missing (queued)")
	}
	if goListenerNextID <= before {
		t.Fatal("next_id should have advanced")
	}
	// 큐에 들어갔는지 확인
	pendingMu.Lock()
	queued := len(pendingListeners)
	pendingMu.Unlock()
	if queued == 0 {
		t.Fatal("expected at least 1 pending listener")
	}
	// 테스트 정리
	Off(id)
	pendingMu.Lock()
	pendingListeners = nil
	pendingMu.Unlock()
}

func TestSendToNoopWithoutCore(t *testing.T) {
	// core 주입 전 SendTo — crash 없어야.
	SendTo(3, "channel", "{}")
}

func TestBuildInvokeEvent(t *testing.T) {
	// JSON 디코더가 숫자를 float64로 주므로 그 타입을 그대로 넘김.
	params := map[string]any{
		"__window":      float64(7),
		"__window_name": "settings",
	}
	ev := buildInvokeEvent(params)
	if ev.Window.ID != 7 {
		t.Fatalf("window.id = %d, want 7", ev.Window.ID)
	}
	if ev.Window.Name != "settings" {
		t.Fatalf("window.name = %q, want %q", ev.Window.Name, "settings")
	}
}

func TestBuildInvokeEventDefaultsWhenMissing(t *testing.T) {
	ev := buildInvokeEvent(map[string]any{"cmd": "ping"})
	if ev.Window.ID != 0 {
		t.Fatalf("window.id = %d, want 0 (default)", ev.Window.ID)
	}
	if ev.Window.Name != "" {
		t.Fatalf("window.name = %q, want empty", ev.Window.Name)
	}
}

func TestBuildInvokeEventRejectsWrongTypes(t *testing.T) {
	// 잘못된 타입은 zero-value로 폴백.
	params := map[string]any{
		"__window":      "not-a-number",
		"__window_name": 42, // 숫자 — string 아님
	}
	ev := buildInvokeEvent(params)
	if ev.Window.ID != 0 || ev.Window.Name != "" {
		t.Fatalf("expected zero-value, got %+v", ev)
	}
}

// 2-arity 메서드 callMethod 경로: InvokeEvent 값이 주입되는지 검증.
type testAppForInvokeEvent struct {
	lastID   uint32
	lastName string
}

// Method 파라미터 순서: (data string, event *suji.InvokeEvent).
// getParamName의 index=0 → "name", 하지만 우리가 params에 "data" 넣어서 확인하려면 "data"=index 2.
// 단순화: 첫 데이터 파라미터 이름 "name"에 값을 실어준다.
func (a *testAppForInvokeEvent) Greet(name string, event *InvokeEvent) string {
	a.lastID = event.Window.ID
	a.lastName = event.Window.Name
	return "hi " + name
}

func TestCallMethodInjectsInvokeEvent(t *testing.T) {
	app := &testAppForInvokeEvent{}
	Bind(app)
	resp := HandleIPC(`{"cmd":"greet","name":"kim","__window":9,"__window_name":"main"}`)
	if app.lastID != 9 {
		t.Fatalf("event.window.id = %d, want 9 (resp=%s)", app.lastID, resp)
	}
	if app.lastName != "main" {
		t.Fatalf("event.window.name = %q, want %q", app.lastName, "main")
	}
}
