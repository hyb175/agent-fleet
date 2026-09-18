// Package snapshot reads fleet.snapshot, the file scripts/snapshotd.sh writes
// once per tick and every fleet renderer reads. The record layout is specified
// in docs/snapshot-format.md; the fixtures under tests/fixtures/snapshot are
// parsed by both this package and the bash consumers so the two cannot drift.
//
// Readers absorb growth: fields are appended at the END of a record, unknown
// trailing fields are ignored, and a missing trailing field reads as the "-"
// sentinel. Never index a field by position from the end.
package snapshot

import (
	"bufio"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
)

// Sentinel is the value a writer emits for "unknown / not applicable".
const Sentinel = "-"

// Agent states, in urgency order (see Rank).
const (
	StateWait    = "wait"
	StateWorking = "working"
	StateDone    = "done"
	StateIdle    = "idle"
)

// Client is one attached tmux client's active view (a C record). Name is "-"
// for the headless fallback record the daemon writes when nobody is attached.
type Client struct {
	Name    string
	Session string
	Window  string
}

// Space is one workspace (an S record). Rollup is the most urgent state of
// its agents, or "none" when it has none. Branch is the git branch of the
// session's active pane, the directory basename outside git, or
// "(unreachable)" for a federated host that is down.
type Space struct {
	Session string
	Rollup  string
	Branch  string
}

// Agent is one agent pane (an A record).
type Agent struct {
	Session     string
	WindowID    string
	WindowIndex string
	WindowName  string
	Pane        string
	Label       string // agent kind; a "~" suffix marks the scrape tier
	State       string
	PaneIndex   string
	Age         int    // seconds in the current state; valid only when HasAge
	HasAge      bool   // false when the writer emitted the sentinel
	Intent      string // task intent, "" when the pane has no task
	Isolation   string // wt / sbx / ctr, "" for host or no task
	Diffstat    string // +A-D from the last attention transition, "" when none
	Race        string // "k/N" when the task is one attempt of a race, "" otherwise
	Index       int    // arrival order in the file, the stable sort tail
}

// Snapshot is one parsed fleet.snapshot.
type Snapshot struct {
	Epoch    int64 // T record: when the daemon wrote the file
	Interval int   // T record: the daemon's poll interval in seconds
	Clients  []Client
	Spaces   []Space
	Agents   []Agent
}

// Parse reads a snapshot. Unknown record types and blank lines are skipped;
// a malformed T record is an error because every staleness decision hangs
// off it.
func Parse(r io.Reader) (*Snapshot, error) {
	s := &Snapshot{Interval: 1}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if len(line) < 2 || line[1] != ' ' {
			continue
		}
		body := line[2:]
		switch line[0] {
		case 'T':
			parts := strings.Fields(body)
			if len(parts) == 0 {
				return nil, fmt.Errorf("snapshot: malformed T record %q", line)
			}
			epoch, err := strconv.ParseInt(parts[0], 10, 64)
			if err != nil {
				return nil, fmt.Errorf("snapshot: malformed T epoch %q", parts[0])
			}
			s.Epoch = epoch
			if len(parts) > 1 {
				if iv, err := strconv.Atoi(parts[1]); err == nil && iv > 0 {
					s.Interval = iv
				}
			}
		case 'C':
			f := fields(body, 3)
			s.Clients = append(s.Clients, Client{Name: f[0], Session: f[1], Window: f[2]})
		case 'S':
			f := fields(body, 3)
			s.Spaces = append(s.Spaces, Space{Session: f[0], Rollup: f[1], Branch: f[2]})
		case 'A':
			f := fields(body, 13)
			a := Agent{
				Session: f[0], WindowID: f[1], WindowIndex: f[2], WindowName: f[3],
				Pane: f[4], Label: f[5], State: f[6], PaneIndex: f[7],
				Intent: blank(f[9]), Isolation: blank(f[10]), Diffstat: blank(f[11]), Race: blank(f[12]),
				Index: len(s.Agents),
			}
			if age, err := strconv.Atoi(f[8]); err == nil && age >= 0 {
				a.Age, a.HasAge = age, true
			}
			s.Agents = append(s.Agents, a)
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return s, nil
}

// fields splits a record body on "|" and pads to n with the sentinel, so a
// row from an older writer reads exactly like a row whose trailing fields
// were unknown. Extra fields from a newer writer are dropped.
func fields(body string, n int) []string {
	f := strings.Split(body, "|")
	for len(f) < n {
		f = append(f, Sentinel)
	}
	return f[:n]
}

func blank(v string) string {
	if v == Sentinel {
		return ""
	}
	return v
}

// StaleAfter is the constant term of the staleness threshold; the full
// threshold is Interval*3 + StaleAfter seconds, shared with the bash readers.
const StaleAfter = 7

// Stale reports whether the daemon has stopped writing: a crashed daemon
// (kill -9 skips its cleanup) leaves the file behind, and rendering frozen
// states as live is worse than a warning. Jumps must be disabled when stale.
func (s *Snapshot) Stale(now int64) bool {
	return now-s.Epoch > int64(s.Interval)*3+StaleAfter
}

// Rank orders states by how urgently they need the user: wait, working,
// done, idle, then anything unknown.
func Rank(state string) int {
	switch state {
	case StateWait:
		return 0
	case StateWorking:
		return 1
	case StateDone:
		return 2
	case StateIdle:
		return 3
	}
	return 4
}

// FormatAge humanizes seconds the way the bash renderers do: 45s, 4m, 2h.
func FormatAge(sec int) string {
	switch {
	case sec < 60:
		return fmt.Sprintf("%ds", sec)
	case sec < 3600:
		return fmt.Sprintf("%dm", sec/60)
	}
	return fmt.Sprintf("%dh", sec/3600)
}

// IsRemote reports whether an id is federated: the remote poller qualifies
// every session, window and pane id of a remote host as "<host>/<id>", and
// the CLI's sanitize_name keeps "/" out of local session names.
func IsRemote(id string) bool { return strings.Contains(id, "/") }

// Host returns the federated host of a qualified id, or "" for a local one.
func Host(id string) string {
	if i := strings.IndexByte(id, '/'); i >= 0 {
		return id[:i]
	}
	return ""
}

// AgentsPerWindow counts agents by window id. Renderers suffix a row title
// with ".<pane index>" only in windows holding more than one agent.
func (s *Snapshot) AgentsPerWindow() map[string]int {
	n := make(map[string]int, len(s.Agents))
	for _, a := range s.Agents {
		n[a.WindowID]++
	}
	return n
}

// Title is the row title renderers agree on: the task intent when the agent
// has one, else the window name; a ".<pane index>" suffix in shared windows.
func (a Agent) Title(perWindow map[string]int) string {
	t := a.WindowName
	if a.Intent != "" {
		t = a.Intent
	}
	if perWindow[a.WindowID] > 1 && a.PaneIndex != "" && a.PaneIndex != Sentinel {
		t += "." + a.PaneIndex
	}
	return t
}

// SortAttention orders agents most-urgent first: Rank ascending, then the
// longest time in state first for the states named in ageStates, then
// arrival order. The picker tiebreaks on age for wait only; the inbox for
// wait and done. Stable, in place.
func SortAttention(agents []Agent, ageStates ...string) {
	useAge := make(map[string]bool, len(ageStates))
	for _, st := range ageStates {
		useAge[st] = true
	}
	ageKey := func(a Agent) int {
		if useAge[a.State] && a.HasAge {
			return a.Age
		}
		return 0
	}
	sort.SliceStable(agents, func(i, j int) bool {
		ri, rj := Rank(agents[i].State), Rank(agents[j].State)
		if ri != rj {
			return ri < rj
		}
		ai, aj := ageKey(agents[i]), ageKey(agents[j])
		if ai != aj {
			return ai > aj
		}
		return agents[i].Index < agents[j].Index
	})
}
