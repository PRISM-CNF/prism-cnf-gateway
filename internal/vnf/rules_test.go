package vnf

import (
	"context"
	"net/netip"
	"strings"
	"testing"

	"nse-ovs-gateway/internal"
	"nse-ovs-gateway/internal/processor"
)

func TestRenderInstallScriptAllowlist(t *testing.T) {
	t.Parallel()

	sessionCtx := mustSessionContext(t)
	policy := &internal.GatewayPolicy{
		Mode: internal.GatewayModeAllowlist,
		Rules: []internal.GatewayRule{
			{
				Name:       "client-server",
				LeftCIDRs:  []netip.Prefix{netip.MustParsePrefix("10.0.0.1/32")},
				RightCIDRs: []netip.Prefix{netip.MustParsePrefix("10.0.0.2/32")},
			},
		},
	}

	script, err := renderInstallScript(sessionCtx, policy, "nsmgwtest")
	if err != nil {
		t.Fatalf("renderInstallScript() error = %v", err)
	}

	expectedSnippets := []string{
		"add table bridge nsmgwtest",
		`add rule bridge nsmgwtest forward iifname "if-in" oifname "if-out" ether type arp accept`,
		`add rule bridge nsmgwtest forward iifname "if-in" oifname "if-out" ether type ip ip saddr 10.0.0.1/32 ip daddr 10.0.0.2/32 accept`,
		`add rule bridge nsmgwtest forward iifname "if-out" oifname "if-in" ether type ip ip saddr 10.0.0.2/32 ip daddr 10.0.0.1/32 accept`,
		`add rule bridge nsmgwtest forward iifname "if-in" oifname "if-out" ether type ip drop`,
		`add rule bridge nsmgwtest forward iifname "if-out" oifname "if-in" ether type ip drop`,
	}

	for _, snippet := range expectedSnippets {
		if !strings.Contains(script, snippet) {
			t.Fatalf("rendered script missing %q\n%s", snippet, script)
		}
	}
}

func TestInstallTrafficRulesLifecycle(t *testing.T) {
	t.Parallel()

	sessionCtx := mustSessionContext(t)
	policy := &internal.GatewayPolicy{
		Mode: internal.GatewayModeDenylist,
		Rules: []internal.GatewayRule{
			{
				Name:       "deny-demo",
				LeftCIDRs:  []netip.Prefix{netip.MustParsePrefix("10.0.0.1/32")},
				RightCIDRs: []netip.Prefix{netip.MustParsePrefix("10.0.0.2/32")},
			},
		},
	}
	runner := &recordingNFTRunner{}

	session, err := installTrafficRules(context.Background(), sessionCtx, policy, runner)
	if err != nil {
		t.Fatalf("installTrafficRules() error = %v", err)
	}

	if len(runner.scripts) != 2 {
		t.Fatalf("runner script count after install = %d, want 2", len(runner.scripts))
	}
	if !strings.Contains(runner.scripts[0], "delete table bridge") {
		t.Fatalf("install pre-clean script missing delete table command\n%s", runner.scripts[0])
	}
	if !strings.Contains(runner.scripts[1], "ether type ip accept") {
		t.Fatalf("denylist install script missing catch-all accept rule\n%s", runner.scripts[1])
	}

	if got, ok := sessionCtx.State().Load(StateKeyGatewayMode); !ok || got != string(internal.GatewayModeDenylist) {
		t.Fatalf("state gateway mode = %v, %v; want %q, true", got, ok, internal.GatewayModeDenylist)
	}
	if got, ok := sessionCtx.State().Load(StateKeyGatewayRules); !ok || got != 1 {
		t.Fatalf("state gateway rules = %v, %v; want 1, true", got, ok)
	}
	if _, ok := sessionCtx.State().Load(StateKeyGatewayTable); !ok {
		t.Fatal("state gateway table missing")
	}

	if err := session.Close(context.Background()); err != nil {
		t.Fatalf("session.Close() error = %v", err)
	}
	if len(runner.scripts) != 3 {
		t.Fatalf("runner script count after cleanup = %d, want 3", len(runner.scripts))
	}
	if !strings.Contains(runner.scripts[2], "delete table bridge") {
		t.Fatalf("cleanup script missing delete table command\n%s", runner.scripts[2])
	}
}

type recordingNFTRunner struct {
	scripts []string
}

func (r *recordingNFTRunner) Run(_ context.Context, script string) error {
	r.scripts = append(r.scripts, script)
	return nil
}

func mustSessionContext(t *testing.T) *SessionContext {
	t.Helper()

	sessionCtx, err := newSessionContext(&processor.Runtime{
		Flow: &processor.Flow{
			ConnectionID:     "conn-1",
			IngressInterface: "if-in",
			EgressInterface:  "if-out",
		},
	})
	if err != nil {
		t.Fatalf("newSessionContext() error = %v", err)
	}
	return sessionCtx
}
