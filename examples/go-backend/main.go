package main

import "github.com/ohah/suji-go"

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

func main() {}
