package suji

import (
	"strings"
	"testing"
)

type tsPingRes struct {
	Msg string `json:"msg"`
}

type tsGreetReq struct {
	Name string `json:"name"`
}

type tsGreetRes struct {
	Greeting string `json:"greeting"`
}

type tsAddReq struct {
	FirstValue  int     `json:"firstValue"`
	SecondValue float64 `json:"secondValue"`
	Ignored     string  `json:"-"`
	Optional    *string `json:"optional,omitempty"`
}

type tsAddRes struct {
	Result int `json:"result"`
}

func TestTSHandlersExportModuleAugmentation(t *testing.T) {
	dts, err := NewTSHandlers().
		Handler("ping", nil, tsPingRes{}).
		Handler("greet", tsGreetReq{}, tsGreetRes{}).
		Handler("math:add", tsAddReq{}, tsAddRes{}).
		Export()
	if err != nil {
		t.Fatal(err)
	}

	checks := []string{
		"declare module '@suji/api'",
		"interface SujiHandlers",
		"ping: { req: void; res: tsPingRes };",
		"greet: { req: tsGreetReq; res: tsGreetRes };",
		"\"math:add\": { req: tsAddReq; res: tsAddRes };",
		"export type tsPingRes =",
		"msg: string",
		"firstValue: number",
		"secondValue: number",
		"optional?: string | null",
		"result: number",
	}
	for _, want := range checks {
		if !strings.Contains(dts, want) {
			t.Fatalf("generated d.ts missing %q:\n%s", want, dts)
		}
	}
	if strings.Contains(dts, "Ignored") {
		t.Fatalf("json:\"-\" field leaked into d.ts:\n%s", dts)
	}
}

func TestTSHandlersExportForNodeModule(t *testing.T) {
	dts, err := NewTSHandlers().Handler("ping", nil, tsPingRes{}).ExportFor("@suji/node")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(dts, "declare module '@suji/node'") {
		t.Fatalf("expected @suji/node augmentation:\n%s", dts)
	}
}
