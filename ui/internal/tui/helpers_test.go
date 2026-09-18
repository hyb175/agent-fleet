package tui

import "github.com/hyb175/agent-fleet/ui/internal/theme"

func testTheme() theme.Theme {
	th, err := theme.Load("../../..", "tokyo-night")
	if err != nil {
		panic(err)
	}
	return th
}
