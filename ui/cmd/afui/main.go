// afui is the fleet's native terminal UI: the rail, the picker, the inbox
// and the move-tab popup, one binary. It is view-only — it reads
// fleet.snapshot and the theme, and runs `agent-fleet` verbs for anything
// that changes state. scripts/ui-launch.sh starts every surface.
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/hyb175/agent-fleet/ui/internal/cache"
	"github.com/hyb175/agent-fleet/ui/internal/inbox"
	"github.com/hyb175/agent-fleet/ui/internal/picker"
	"github.com/hyb175/agent-fleet/ui/internal/rail"
	"github.com/hyb175/agent-fleet/ui/internal/theme"
)

// version is set at build time: -ldflags "-X main.version=<AGENT_FLEET_VERSION>".
var version = "dev"

func usage() {
	fmt.Fprint(os.Stderr, `usage: afui <rail|pick [fleet|spaces|connect]|inbox|move|version|env>

  rail     the sidenav rail (runs inside a tmux pane)
  pick     the picker popup (fleet | spaces | connect)
  inbox    the attention inbox popup
  move     the move-tab destination picker ([@window-id])
  version  print the fleet version this binary was built with
  env      print the resolved root, cache dir, snapshot path and theme
`)
}

// root is where conf/themes lives: AGENT_FLEET_ROOT (exported into the
// server env by the CLI), else the parent of the binary's directory (a dev
// checkout builds to <repo>/bin/afui).
func root() string {
	if r := os.Getenv("AGENT_FLEET_ROOT"); r != "" {
		return r
	}
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	return filepath.Dir(filepath.Dir(exe))
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "version", "-V", "--version":
		fmt.Printf("afui %s\n", version)
	case "env":
		th, err := theme.Resolve(root(), os.Getenv)
		fmt.Printf("root=%s\ncache=%s\nsnapshot=%s\n", root(), cache.Dir(os.Getenv), cache.Snapshot(os.Getenv))
		if err != nil {
			fmt.Printf("theme=(unreadable: %v)\n", err)
			os.Exit(1)
		}
		fmt.Printf("theme=%s accent=%s\n", th.Name, th.Accent)
	case "rail":
		cfg, err := rail.Load(os.Getenv, root())
		if err != nil {
			fmt.Fprintf(os.Stderr, "afui rail: %v\n", err)
			os.Exit(1)
		}
		if err := rail.Run(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "afui rail: %v\n", err)
			os.Exit(1)
		}
	case "pick", "move":
		view := picker.Move
		moveWin := ""
		if os.Args[1] == "pick" {
			view = picker.Fleet
			if len(os.Args) > 2 {
				view = picker.ParseView(os.Args[2])
			}
		} else if len(os.Args) > 2 {
			moveWin = os.Args[2] // an explicit window id wins (CLI/tests)
		}
		cfg, err := picker.Load(os.Getenv, root(), view, moveWin)
		if err != nil {
			fmt.Fprintf(os.Stderr, "afui %s: %v\n", os.Args[1], err)
			os.Exit(1)
		}
		if err := picker.Run(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "afui %s: %v\n", os.Args[1], err)
			os.Exit(1)
		}
	case "inbox":
		cfg, err := inbox.Load(os.Getenv, root())
		if err != nil {
			fmt.Fprintf(os.Stderr, "afui inbox: %v\n", err)
			os.Exit(1)
		}
		if err := inbox.Run(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "afui inbox: %v\n", err)
			os.Exit(1)
		}
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "afui: unknown subcommand %q\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}
