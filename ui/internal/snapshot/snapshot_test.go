package snapshot

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const fixtures = "../../../tests/fixtures/snapshot"

func load(t *testing.T, name string) *Snapshot {
	t.Helper()
	f, err := os.Open(filepath.Join(fixtures, name))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	s, err := Parse(f)
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return s
}

func TestEveryFixtureParses(t *testing.T) {
	names, err := filepath.Glob(filepath.Join(fixtures, "*.snapshot"))
	if err != nil || len(names) == 0 {
		t.Fatalf("no fixtures: %v", err)
	}
	for _, n := range names {
		load(t, filepath.Base(n))
	}
}

func TestRaceField(t *testing.T) {
	s := load(t, "race.snapshot")
	if s.Agents[0].Race != "1/2" || s.Agents[1].Race != "2/2" {
		t.Fatalf("race badges: %q %q", s.Agents[0].Race, s.Agents[1].Race)
	}
	if s.Agents[2].Race != "" {
		t.Fatalf("12-field row reads no race, got %q", s.Agents[2].Race)
	}
}

func TestMixedFields(t *testing.T) {
	s := load(t, "mixed.snapshot")
	if s.Epoch != 1789500000 || s.Interval != 1 {
		t.Fatalf("T: got %d %d", s.Epoch, s.Interval)
	}
	if len(s.Clients) != 2 || s.Clients[1].Window != "@5" {
		t.Fatalf("clients: %+v", s.Clients)
	}
	if len(s.Spaces) != 3 || s.Spaces[2].Rollup != "none" {
		t.Fatalf("spaces: %+v", s.Spaces)
	}
	if len(s.Agents) != 6 {
		t.Fatalf("agents: %d", len(s.Agents))
	}
	a := s.Agents[3] // %9
	if a.Pane != "%9" || a.State != StateWait || !a.HasAge || a.Age != 900 ||
		a.Intent != "migrate the auth table" || a.Isolation != "sbx" || a.Diffstat != "+120-8" {
		t.Fatalf("%%9: %+v", a)
	}
	if b := s.Agents[0]; b.HasAge || b.Diffstat != "" || b.Isolation != "wt" || b.Label != "claude" {
		t.Fatalf("%%3: %+v", b)
	}
	if c := s.Agents[2]; c.Intent != "" || c.Label != "codex~" || c.PaneIndex != "2" {
		t.Fatalf("%%7: %+v", c)
	}
}

func TestExtraTrailingFieldParsesIdentically(t *testing.T) {
	base := load(t, "mixed.snapshot")
	extra := load(t, "extra-field.snapshot")
	if len(base.Agents) != len(extra.Agents) {
		t.Fatalf("agent count differs: %d vs %d", len(base.Agents), len(extra.Agents))
	}
	for i := range base.Agents {
		if base.Agents[i] != extra.Agents[i] {
			t.Fatalf("agent %d differs:\n base  %+v\n extra %+v", i, base.Agents[i], extra.Agents[i])
		}
	}
}

func TestShortRowsReadAsSentinels(t *testing.T) {
	s := load(t, "short-rows.snapshot")
	if s.Interval != 1 {
		t.Fatalf("T without interval must default to 1, got %d", s.Interval)
	}
	if len(s.Agents) != 2 {
		t.Fatalf("agents: %d", len(s.Agents))
	}
	if a := s.Agents[0]; !a.HasAge || a.Age != 45 || a.Intent != "" || a.Isolation != "" || a.Diffstat != "" {
		t.Fatalf("9-field row: %+v", a)
	}
	if b := s.Agents[1]; b.State != StateIdle || b.PaneIndex != Sentinel || b.HasAge {
		t.Fatalf("7-field row: %+v", b)
	}
}

func TestPipeSubstitution(t *testing.T) {
	s := load(t, "pipe-name.snapshot")
	if s.Agents[0].WindowName != "fix ¦ retry" || s.Agents[0].Intent != "split a¦b into two" || s.Spaces[0].Branch != "a¦b" {
		t.Fatalf("substituted delimiter must survive as one field: %+v %+v", s.Agents[0], s.Spaces[0])
	}
}

func TestRemoteRows(t *testing.T) {
	up := load(t, "remote-up.snapshot")
	r := up.Agents[1]
	if !IsRemote(r.Pane) || Host(r.Pane) != "devbox" || Host(r.Session) != "devbox" || IsRemote(up.Agents[0].Pane) {
		t.Fatalf("remote qualification: %+v", r)
	}
	down := load(t, "remote-down.snapshot")
	if len(down.Agents) != 0 || down.Spaces[1].Branch != "(unreachable)" || down.Spaces[1].Rollup != "none" {
		t.Fatalf("down host must collapse to one workspace row: %+v", down.Spaces)
	}
}

func TestStale(t *testing.T) {
	fresh := load(t, "mixed.snapshot")
	if fresh.Stale(fresh.Epoch + 10) {
		t.Fatal("10s at interval 1 is within 3*1+7")
	}
	if !fresh.Stale(fresh.Epoch + 11) {
		t.Fatal("11s at interval 1 is past 3*1+7")
	}
	stale := load(t, "stale.snapshot")
	if !stale.Stale(1789500000) {
		t.Fatal("a T 60s old must read stale")
	}
	slow := &Snapshot{Epoch: 1000, Interval: 5}
	if slow.Stale(1000+22) || !slow.Stale(1000+23) {
		t.Fatal("threshold must scale with the interval (5*3+7=22)")
	}
}

func TestPickerOrderMatchesBash(t *testing.T) {
	s := load(t, "mixed.snapshot")
	want, err := os.ReadFile(filepath.Join(fixtures, "mixed.picker-order"))
	if err != nil {
		t.Fatal(err)
	}
	agents := append([]Agent(nil), s.Agents...)
	SortAttention(agents, StateWait)
	got := make([]string, len(agents))
	for i, a := range agents {
		got[i] = a.Pane
	}
	if g, w := strings.Join(got, "\n"), strings.TrimSpace(string(want)); g != w {
		t.Fatalf("picker order\n got  %q\n want %q", g, w)
	}
}

func TestTitleAndAge(t *testing.T) {
	s := load(t, "mixed.snapshot")
	per := s.AgentsPerWindow()
	if got := s.Agents[1].Title(per); got != "fix the flaky spec.1" {
		t.Fatalf("shared window title: %q", got)
	}
	if got := s.Agents[2].Title(per); got != "fix-tests.2" {
		t.Fatalf("no-intent shared window title: %q", got)
	}
	if got := s.Agents[0].Title(per); got != "review the login flow" {
		t.Fatalf("solo window title: %q", got)
	}
	for sec, want := range map[int]string{0: "0s", 45: "45s", 60: "1m", 240: "4m", 3599: "59m", 3600: "1h", 7300: "2h"} {
		if got := FormatAge(sec); got != want {
			t.Fatalf("FormatAge(%d) = %q, want %q", sec, got, want)
		}
	}
}
