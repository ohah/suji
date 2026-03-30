// Package suji provides the Go SDK for the Suji desktop framework.
//
// Electron-style API:
//   Handle — 요청/응답 (ipcMain.handle)
//   On     — 이벤트 수신 (ipcMain.on)
//   Send   — 이벤트 발신 (webContents.send)
//   Invoke — 다른 백엔드 호출 (ipcRenderer.invoke)
//
//	type App struct{}
//	func (a *App) Ping() string { return "pong" }
//	var _ = suji.Bind(&App{})
package suji

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"sync"
)

type M = map[string]any

var (
	handlers = make(map[string]reflect.Method)
	target   any
	mu       sync.RWMutex
)

// Bind registers all public methods as handlers.
// Method names are auto-converted: PascalCase → snake_case.
func Bind(app any) bool {
	mu.Lock()
	defer mu.Unlock()
	target = app
	t := reflect.TypeOf(app)
	for i := 0; i < t.NumMethod(); i++ {
		method := t.Method(i)
		handlers[toSnakeCase(method.Name)] = method
	}
	return true
}

// HandleIPC processes an IPC request (called internally by C ABI).
func HandleIPC(reqStr string) string {
	var reqMap map[string]any
	if err := json.Unmarshal([]byte(reqStr), &reqMap); err != nil {
		return `{"from":"go","error":"invalid json"}`
	}
	cmd, _ := reqMap["cmd"].(string)
	if cmd == "" {
		return `{"from":"go","error":"no cmd"}`
	}

	mu.RLock()
	method, ok := handlers[cmd]
	mu.RUnlock()
	if !ok {
		return fmt.Sprintf(`{"from":"go","error":"unknown: %s"}`, cmd)
	}

	result := callMethod(method, reqMap)
	resp := M{"from": "go", "cmd": cmd, "result": result}
	bytes, _ := json.Marshal(resp)
	return string(bytes)
}

func callMethod(method reflect.Method, params map[string]any) any {
	mu.RLock()
	t := target
	mu.RUnlock()

	args := []reflect.Value{reflect.ValueOf(t)}
	for i := 1; i < method.Type.NumIn(); i++ {
		paramType := method.Type.In(i)
		name := getParamName(method.Name, i-1)
		if raw, ok := params[name]; ok {
			args = append(args, convertValue(raw, paramType))
		} else {
			args = append(args, reflect.Zero(paramType))
		}
	}

	results := method.Func.Call(args)
	if len(results) == 0 {
		return nil
	}
	return results[0].Interface()
}

func getParamName(_ string, index int) string {
	names := []string{"name", "text", "data", "value", "msg"}
	if index < len(names) {
		return names[index]
	}
	return string(rune('a' + index))
}

func convertValue(raw any, targetType reflect.Type) reflect.Value {
	switch targetType.Kind() {
	case reflect.String:
		if s, ok := raw.(string); ok {
			return reflect.ValueOf(s)
		}
		return reflect.ValueOf(fmt.Sprintf("%v", raw))
	case reflect.Int, reflect.Int64:
		if f, ok := raw.(float64); ok {
			return reflect.ValueOf(int64(f)).Convert(targetType)
		}
		return reflect.Zero(targetType)
	case reflect.Float64:
		if f, ok := raw.(float64); ok {
			return reflect.ValueOf(f)
		}
		return reflect.Zero(targetType)
	case reflect.Bool:
		if b, ok := raw.(bool); ok {
			return reflect.ValueOf(b)
		}
		return reflect.Zero(targetType)
	default:
		bytes, _ := json.Marshal(raw)
		ptr := reflect.New(targetType)
		json.Unmarshal(bytes, ptr.Interface())
		return ptr.Elem()
	}
}

func toSnakeCase(s string) string {
	var result strings.Builder
	for i, r := range s {
		if i > 0 && r >= 'A' && r <= 'Z' {
			result.WriteByte('_')
		}
		result.WriteRune(r)
	}
	return strings.ToLower(result.String())
}
