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
