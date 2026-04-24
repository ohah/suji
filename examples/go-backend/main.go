package main

import (
	"fmt"
	"os"

	"github.com/ohah/suji-go"
)

type App struct{}

func (a *App) Ping() string {
	return "pong"
}

func (a *App) Greet(name string) string {
	return "Hello, " + name
}

func (a *App) Upper(name string) string {
	return name
}

func (a *App) Words(name string) int {
	count := 0
	for _, c := range name {
		if c == ' ' {
			count++
		}
	}
	return count + 1
}

var _ = suji.Bind(&App{})

// Electron 패턴: window:all-closed 이벤트에서 플랫폼별 quit.
// macOS는 창 닫혀도 앱 유지 (dock), 나머지는 종료.
func onWindowAllClosed(channel, data string) {
	_ = channel
	_ = data
	p := suji.Platform()
	fmt.Fprintf(os.Stderr, "[Go] window-all-closed received (platform=%s)\n", p)
	if p != suji.PlatformMacOS {
		fmt.Fprintln(os.Stderr, "[Go] non-macOS → suji.Quit()")
		suji.Quit()
	}
}

func init() {
	suji.On("window:all-closed", onWindowAllClosed)
}

func main() {}
