// Package suji provides the Go SDK for the Suji desktop framework.
//
// Usage:
//
//	type App struct{}
//	func (a *App) Ping() string { return "pong" }
//	func (a *App) Greet(name string) string { return "Hello, " + name }
//	var _ = suji.Bind(&App{})
package suji

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"sync"
)

// M is a shorthand for map[string]any (JSON object)
type M = map[string]any

// Request wraps the incoming JSON request
type Request struct {
	raw map[string]any
}

// String returns a string parameter
func (r *Request) String(key string) string {
	if v, ok := r.raw[key]; ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}

// Int returns an int64 parameter
func (r *Request) Int(key string) int64 {
	if v, ok := r.raw[key]; ok {
		if f, ok := v.(float64); ok {
			return int64(f)
		}
	}
	return 0
}

// Float returns a float64 parameter
func (r *Request) Float(key string) float64 {
	if v, ok := r.raw[key]; ok {
		if f, ok := v.(float64); ok {
			return f
		}
	}
	return 0
}

// Bool returns a boolean parameter
func (r *Request) Bool(key string) bool {
	if v, ok := r.raw[key]; ok {
		if b, ok := v.(bool); ok {
			return b
		}
	}
	return false
}

// Raw returns the raw map
func (r *Request) Raw() map[string]any {
	return r.raw
}

// handler registry
var (
	handlers = make(map[string]reflect.Method)
	target   any
	mu       sync.RWMutex
)

// Bind registers all public methods of the struct as commands.
// Method names are converted to snake_case for command names.
//
//	type App struct{}
//	func (a *App) Ping() string { return "pong" }
//	var _ = suji.Bind(&App{})
func Bind(app any) bool {
	mu.Lock()
	defer mu.Unlock()

	target = app
	t := reflect.TypeOf(app)

	for i := 0; i < t.NumMethod(); i++ {
		method := t.Method(i)
		name := toSnakeCase(method.Name)
		handlers[name] = method
	}

	return true
}

// HandleIPC processes an IPC request and returns a JSON response.
// This is called internally by the C ABI export.
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
		return fmt.Sprintf(`{"from":"go","error":"unknown command: %s"}`, cmd)
	}

	// 메서드 호출
	result := callMethod(method, reqMap)

	// 응답 JSON 생성
	resp := M{
		"from":   "go",
		"cmd":    cmd,
		"result": result,
	}

	bytes, err := json.Marshal(resp)
	if err != nil {
		return `{"from":"go","error":"marshal failed"}`
	}

	return string(bytes)
}

// callMethod invokes a method with parameters extracted from the request
func callMethod(method reflect.Method, params map[string]any) any {
	mu.RLock()
	t := target
	mu.RUnlock()

	methodType := method.Type
	numIn := methodType.NumIn() // 첫 번째는 receiver

	args := []reflect.Value{reflect.ValueOf(t)}

	// 파라미터 매칭: 메서드 시그니처에서 파라미터 이름은 알 수 없으므로
	// 파라미터 타입에 따라 JSON 값을 변환
	for i := 1; i < numIn; i++ {
		paramType := methodType.In(i)
		paramName := getParamName(method.Name, i-1)

		var val reflect.Value

		if raw, ok := params[paramName]; ok {
			val = convertValue(raw, paramType)
		} else {
			val = reflect.Zero(paramType)
		}

		args = append(args, val)
	}

	results := method.Func.Call(args)

	if len(results) == 0 {
		return nil
	}

	return results[0].Interface()
}

// getParamName tries to find param name from common patterns
// Go reflection doesn't provide param names, so we use position-based naming
func getParamName(methodName string, index int) string {
	// 일반적인 파라미터 이름 패턴
	commonNames := [][]string{
		{"name", "text", "msg", "data", "value", "input"},
		{"b", "count", "size", "limit"},
	}

	if index < len(commonNames) {
		for _, name := range commonNames[index] {
			return name
		}
	}

	// fallback: a, b, c...
	return string(rune('a' + index))
}

// convertValue converts a JSON value to the target reflect.Type
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
		// 복잡한 타입은 JSON 재직렬화로 처리
		bytes, err := json.Marshal(raw)
		if err != nil {
			return reflect.Zero(targetType)
		}
		ptr := reflect.New(targetType)
		if err := json.Unmarshal(bytes, ptr.Interface()); err != nil {
			return reflect.Zero(targetType)
		}
		return ptr.Elem()
	}
}

// toSnakeCase converts PascalCase to snake_case
// Greet -> greet, AddNumbers -> add_numbers
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
