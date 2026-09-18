package tui

import (
	"fmt"
	"os/exec"
	"strings"
	"testing"
)

func TestCksumMatchesCoreutils(t *testing.T) {
	if _, err := exec.LookPath("cksum"); err != nil {
		t.Skip("no cksum on PATH")
	}
	for _, s := range []string{"", "a", "hello\n", strings.Repeat("Proceed? [y/N]\n", 40)} {
		cmd := exec.Command("cksum")
		cmd.Stdin = strings.NewReader(s)
		out, err := cmd.Output()
		if err != nil {
			t.Fatal(err)
		}
		var want uint32
		fmt.Sscanf(string(out), "%d", &want)
		if got := Cksum([]byte(s)); got != want {
			t.Fatalf("Cksum(%q) = %d, cksum says %d", s, got, want)
		}
	}
}

func TestBoxPinsCount(t *testing.T) {
	p := NewPalette(testTheme())
	box := Plain(p.Box(40, "› "+strings.Repeat("x", 60), "3 of 9"))
	lines := strings.Split(box, "\n")
	if len(lines) != 3 || !strings.HasSuffix(lines[1], "3 of 9 │") {
		t.Fatalf("count must stay visible: %q", lines[1])
	}
	for _, l := range lines {
		if w := len([]rune(l)); w != 40 {
			t.Fatalf("box line %d cells wide, want 40: %q", w, l)
		}
	}
}

func TestDiffAndTrunc(t *testing.T) {
	if Diff("+31-2") != "+31 −2" || Diff("-") != "-" {
		t.Fatal("diff spacing")
	}
	if Trunc("認証テーブル", 5) != "認証…" {
		t.Fatalf("cell-width truncation: %q", Trunc("認証テーブル", 5))
	}
}
