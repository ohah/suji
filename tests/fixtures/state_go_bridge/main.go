// 테스트 전용 백엔드: suji-plugin-state (Go 래퍼)가 실제로 state dylib로
// invoke를 라우팅하는지 end-to-end 검증용. 통합 테스트에서만 로드.
//
// suji.Bind는 파라미터를 positional로 매핑한다:
//   index 0 → "name", index 1 → "text"
// 그래서 JSON 요청은 {"cmd":"go_state_set","name":"foo","text":"\"bar\""} 형태다.
package main

import (
	suji "github.com/ohah/suji-go"
	state "github.com/ohah/suji-plugin-state"
)

type App struct{}

func (a *App) GoStateSet(name, text string) map[string]any {
	state.Set(name, text)
	return map[string]any{"ok": true}
}

func (a *App) GoStateGet(name string) map[string]any {
	v := state.Get(name)
	if v == "" {
		return map[string]any{"value": nil}
	}
	return map[string]any{"value": v}
}

func (a *App) GoStateDelete(name string) map[string]any {
	state.Delete(name)
	return map[string]any{"ok": true}
}

func (a *App) GoStateKeys() map[string]any {
	return map[string]any{"keys": state.Keys()}
}

func (a *App) GoStateClear() map[string]any {
	state.Clear()
	return map[string]any{"ok": true}
}

var _ = suji.Bind(&App{})

func main() {}
