package inbox

import (
	"os"
	"os/exec"
	"regexp"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/hyb175/agent-fleet/ui/internal/snapshot"
	"github.com/hyb175/agent-fleet/ui/internal/theme"
	"github.com/hyb175/agent-fleet/ui/internal/tui"
)

var ansi = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func plain(s string) string { return ansi.ReplaceAllString(s, "") }

func load(t *testing.T, name string) *snapshot.Snapshot {
	t.Helper()
	f, err := os.Open("../../../tests/fixtures/snapshot/" + name)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	s, err := snapshot.Parse(f)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestItemsQueueOrderAndMarkers(t *testing.T) {
	items := Items(load(t, "mixed.snapshot"), 600)
	var panes []string
	for _, it := range items {
		panes = append(panes, it.Pane)
	}
	// wait rows longest first (%9 900s, %4 240s), then done longest first (%10 7300s, %11 30s).
	if strings.Join(panes, " ") != "%9 %4 %10 %11" {
		t.Fatalf("queue order: %v", panes)
	}
	if items[0].Group != "needs you" || items[0].Right != "15m !" || items[0].Iso != "sbx" || items[0].Diff != "+120-8" {
		t.Fatalf("escalated wait row: %+v", items[0])
	}
	if items[1].Right != "4m" {
		t.Fatalf("fresh wait unmarked: %+v", items[1])
	}
	if items[2].Group != "done" || items[2].Right != "2h" || items[2].Diff != "+5-0" {
		t.Fatalf("done row: %+v", items[2])
	}
	if items := Items(load(t, "mixed.snapshot"), 0); items[0].Right != "15m" {
		t.Fatal("escalation 0 disables the marker")
	}
	rem := Items(load(t, "remote-up.snapshot"), 600)
	if len(rem) != 1 || !rem[0].Remote || rem[0].Right != "2m" {
		t.Fatalf("remote wait row: %+v", rem)
	}
}

func TestFingerprintMatchesBashPipeline(t *testing.T) {
	if _, err := exec.LookPath("cksum"); err != nil {
		t.Skip("no cksum")
	}
	// A capture-pane output: content, trailing spaces, blank rows at the bottom.
	cap := "Proceed with the demo? [y/N]   \n  1. yes\n  2. no\n\n\n\n"
	// inbox.sh: cap="$(tmux capture-pane -p …)"; printf '%s' "$cap" | sed -e 's/[[:space:]]*$//' | cksum
	cmd := exec.Command("bash", "-c", `cap="$(printf '%s' "$1")"; printf '%s' "$cap" | sed -e 's/[[:space:]]*$//' | cksum | awk '{print $1}'`, "_", cap)
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	if got, want := Fingerprint(cap), strings.TrimSpace(string(out)); got != want {
		t.Fatalf("Fingerprint = %s, bash pipeline = %s", got, want)
	}
	if Fingerprint("\n\n") != "" {
		t.Fatal("an empty capture has no fingerprint")
	}
}

func TestTailCollapsesBlankRuns(t *testing.T) {
	got := Tail("a\n\n\n\nb   \nc\n\n\n", 18)
	if strings.Join(got, "|") != "a||b|c" {
		t.Fatalf("%q", got)
	}
	if got := Tail("1\n2\n3\n4", 2); strings.Join(got, "|") != "3|4" {
		t.Fatalf("tail: %q", got)
	}
}

func TestViewLayout(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	th, err := theme.Load("../../..", "tokyo-night")
	if err != nil {
		t.Fatal(err)
	}
	m := model{cfg: Config{Width: 78, Height: 26, Escalate: 600}, p: tui.NewPalette(th)}
	m.items = Items(load(t, "mixed.snapshot"), 600)
	m.refilter()
	m.preview = Preview{Pane: "%9", Lines: []string{"Allow Bash(git push)?", "", "  1. Yes", "  2. No"}, FP: "123"}
	out := plain(m.View())
	t.Logf("\n%s", out)
	lines := strings.Split(out, "\n")
	if !strings.Contains(lines[0], "inbox") || !strings.Contains(lines[0], "2 need you · 2 done") {
		t.Fatalf("header: %q", lines[0])
	}
	if !strings.Contains(out, "NEEDS YOU") || !strings.Contains(out, "DONE") {
		t.Fatal("group headers")
	}
	if !strings.Contains(out, "15m !") {
		t.Fatal("escalation marker in the right column")
	}
	if !strings.Contains(out, "what it is asking") || !strings.Contains(out, "Allow Bash(git push)?") {
		t.Fatalf("preview panel:\n%s", out)
	}
	if !strings.Contains(lines[len(lines)-1], "^y approve") || !strings.Contains(lines[len(lines)-1], "^n deny") {
		t.Fatalf("footer: %q", lines[len(lines)-1])
	}
	for _, l := range lines {
		if w := len([]rune(l)); w > 78 {
			t.Fatalf("line wider than the popup (%d): %q", w, l)
		}
	}
	// Answer guard: no preview fingerprint for the row -> refused locally.
	m.preview = Preview{}
	nm, cmd := m.answer("approve", "")
	if cmd != nil || !strings.HasPrefix(nm.(model).note, "not sent: no fingerprint") {
		t.Fatalf("answer without a fingerprint must refuse: %q", nm.(model).note)
	}
	// Done row -> refused as not waiting.
	m.cursor = 2
	nm, cmd = m.answer("approve", "")
	if cmd != nil || !strings.Contains(nm.(model).note, "answers are for waiting agents") {
		t.Fatalf("done row refusal: %q", nm.(model).note)
	}
}

func TestPostAnswerRefetchIsForTheAnsweredRowOnly(t *testing.T) {
	th, _ := theme.Load("../../..", "tokyo-night")
	m := model{cfg: Config{Width: 78, Height: 26}, p: tui.NewPalette(th)}
	items := Items(load(t, "mixed.snapshot"), 600)
	// Cursor moved to the second row after answering the first; its preview is the user's last look.
	m.items = items
	m.refilter()
	m.cursor = 1
	m.preview = Preview{Pane: items[1].Pane, FP: "1"}
	if _, cmd := m.Update(itemsMsg{items: items, tot: len(items), refetch: items[0].Pane}); cmd != nil {
		t.Fatal("refetch for the answered row must not re-bless the row the cursor moved to")
	}
	if _, cmd := m.Update(itemsMsg{items: items, tot: len(items), refetch: items[1].Pane}); cmd == nil {
		t.Fatal("refetch for the selected row fetches")
	}
	if _, cmd := m.Update(itemsMsg{items: items, tot: len(items), refetch: "*"}); cmd == nil {
		t.Fatal("^r refetches whatever is selected")
	}
}

func TestTypingKeepsSpaces(t *testing.T) {
	th, _ := theme.Load("../../..", "tokyo-night")
	m := model{cfg: Config{Width: 78, Height: 26}, p: tui.NewPalette(th)}
	m.items = Items(load(t, "mixed.snapshot"), 600)
	m.refilter()
	m.mode = typing
	for _, k := range []tea.KeyMsg{{Type: tea.KeyRunes, Runes: []rune("yes")}, {Type: tea.KeySpace, Runes: []rune{' '}}, {Type: tea.KeyRunes, Runes: []rune("please")}} {
		nm, _ := m.Update(k)
		m = nm.(model)
	}
	if m.reply != "yes please" {
		t.Fatalf("reply lost the space: %q", m.reply)
	}
}
