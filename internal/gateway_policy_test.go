package internal

import "testing"

func TestParseGatewayPolicyAllowlist(t *testing.T) {
	t.Parallel()

	policy, err := ParseGatewayPolicy([]byte(`
mode: allowlist
rules:
  - name: client-server
    left_cidrs:
      - 10.0.0.1/32
    right_cidrs:
      - 10.0.0.2
`))
	if err != nil {
		t.Fatalf("ParseGatewayPolicy() error = %v", err)
	}

	if policy.Mode != GatewayModeAllowlist {
		t.Fatalf("policy.Mode = %q, want %q", policy.Mode, GatewayModeAllowlist)
	}
	if len(policy.Rules) != 1 {
		t.Fatalf("len(policy.Rules) = %d, want 1", len(policy.Rules))
	}

	rule := policy.Rules[0]
	if rule.Name != "client-server" {
		t.Fatalf("rule.Name = %q, want client-server", rule.Name)
	}
	if got := rule.LeftCIDRs[0].String(); got != "10.0.0.1/32" {
		t.Fatalf("left CIDR = %q, want 10.0.0.1/32", got)
	}
	if got := rule.RightCIDRs[0].String(); got != "10.0.0.2/32" {
		t.Fatalf("right CIDR = %q, want 10.0.0.2/32", got)
	}
}

func TestParseGatewayPolicyAllowsEmptyRules(t *testing.T) {
	t.Parallel()

	policy, err := ParseGatewayPolicy([]byte("mode: denylist\nrules: []\n"))
	if err != nil {
		t.Fatalf("ParseGatewayPolicy() error = %v", err)
	}

	if policy.Mode != GatewayModeDenylist {
		t.Fatalf("policy.Mode = %q, want %q", policy.Mode, GatewayModeDenylist)
	}
	if len(policy.Rules) != 0 {
		t.Fatalf("len(policy.Rules) = %d, want 0", len(policy.Rules))
	}
}

func TestParseGatewayPolicyRejectsIPv6(t *testing.T) {
	t.Parallel()

	_, err := ParseGatewayPolicy([]byte(`
mode: allowlist
rules:
  - left_cidrs:
      - 2001:db8::/64
    right_cidrs:
      - 10.0.0.2/32
`))
	if err == nil {
		t.Fatal("ParseGatewayPolicy() error = nil, want IPv6 validation error")
	}
}

func TestParseGatewayPolicyRejectsMissingMode(t *testing.T) {
	t.Parallel()

	_, err := ParseGatewayPolicy([]byte(`
rules:
  - left_cidrs:
      - 10.0.0.1/32
    right_cidrs:
      - 10.0.0.2/32
`))
	if err == nil {
		t.Fatal("ParseGatewayPolicy() error = nil, want missing mode validation error")
	}
}
