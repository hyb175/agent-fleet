package cache

import "testing"

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestDirMatchesCacheSh(t *testing.T) {
	cases := []struct {
		env  map[string]string
		want string
	}{
		{map[string]string{"XDG_CACHE_HOME": "/x", "AGENT_FLEET_SOCKET": "agent-fleet"}, "/x/agent-fleet/agent-fleet"},
		{map[string]string{"XDG_CACHE_HOME": "/x"}, "/x/agent-fleet/agent-fleet"},
		{map[string]string{"XDG_CACHE_HOME": "/x", "AGENT_FLEET_SOCKET": "af-test-123"}, "/x/agent-fleet/af-test-123"},
		{map[string]string{"XDG_CACHE_HOME": "/x", "AGENT_FLEET_SOCKET": "odd/name with:chars"}, "/x/agent-fleet/odd_name_with_chars"},
		{map[string]string{"HOME": "/home/u"}, "/home/u/.cache/agent-fleet/agent-fleet"},
	}
	for _, c := range cases {
		if got := Dir(env(c.env)); got != c.want {
			t.Errorf("Dir(%v) = %q, want %q", c.env, got, c.want)
		}
	}
	if got := Snapshot(env(map[string]string{"XDG_CACHE_HOME": "/x"})); got != "/x/agent-fleet/agent-fleet/fleet.snapshot" {
		t.Errorf("Snapshot = %q", got)
	}
}
