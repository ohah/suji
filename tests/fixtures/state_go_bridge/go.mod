module state-go-bridge

go 1.26

require (
	github.com/ohah/suji-go v0.0.0
	github.com/ohah/suji-plugin-state v0.0.0
)

replace (
	github.com/ohah/suji-go => ../../../sdks/suji-go
	github.com/ohah/suji-plugin-state => ../../../plugins/state/go
)
