package internal

import (
	"fmt"
	"net/netip"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

type GatewayMode string

const (
	GatewayModeAllowlist GatewayMode = "allowlist"
	GatewayModeDenylist  GatewayMode = "denylist"
)

type GatewayPolicy struct {
	Mode  GatewayMode
	Rules []GatewayRule
}

type GatewayRule struct {
	Name       string
	LeftCIDRs  []netip.Prefix
	RightCIDRs []netip.Prefix
}

type rawGatewayPolicy struct {
	Mode  string           `yaml:"mode"`
	Rules []rawGatewayRule `yaml:"rules"`
}

type rawGatewayRule struct {
	Name       string   `yaml:"name"`
	LeftCIDRs  []string `yaml:"left_cidrs"`
	RightCIDRs []string `yaml:"right_cidrs"`
}

func LoadGatewayPolicyFromFile(path string) (*GatewayPolicy, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("gateway rules path is required")
	}

	rawData, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read gateway rules file: %w", err)
	}

	return ParseGatewayPolicy(rawData)
}

func ParseGatewayPolicy(rawData []byte) (*GatewayPolicy, error) {
	var raw rawGatewayPolicy
	if err := yaml.Unmarshal(rawData, &raw); err != nil {
		return nil, fmt.Errorf("unmarshal gateway rules YAML: %w", err)
	}

	mode, err := normalizeGatewayMode(raw.Mode)
	if err != nil {
		return nil, err
	}

	policy := &GatewayPolicy{
		Mode:  mode,
		Rules: make([]GatewayRule, 0, len(raw.Rules)),
	}

	for index, rule := range raw.Rules {
		leftCIDRs, err := parseGatewayPrefixes(rule.LeftCIDRs, "left_cidrs")
		if err != nil {
			return nil, fmt.Errorf("rule %d: %w", index+1, err)
		}

		rightCIDRs, err := parseGatewayPrefixes(rule.RightCIDRs, "right_cidrs")
		if err != nil {
			return nil, fmt.Errorf("rule %d: %w", index+1, err)
		}

		name := strings.TrimSpace(rule.Name)
		if name == "" {
			name = fmt.Sprintf("rule-%d", index+1)
		}

		policy.Rules = append(policy.Rules, GatewayRule{
			Name:       name,
			LeftCIDRs:  leftCIDRs,
			RightCIDRs: rightCIDRs,
		})
	}

	return policy, nil
}

func normalizeGatewayMode(value string) (GatewayMode, error) {
	switch GatewayMode(strings.ToLower(strings.TrimSpace(value))) {
	case GatewayModeAllowlist:
		return GatewayModeAllowlist, nil
	case GatewayModeDenylist:
		return GatewayModeDenylist, nil
	default:
		return "", fmt.Errorf("invalid gateway mode %q", value)
	}
}

func parseGatewayPrefixes(rawCIDRs []string, fieldName string) ([]netip.Prefix, error) {
	if len(rawCIDRs) == 0 {
		return nil, fmt.Errorf("%s must not be empty", fieldName)
	}

	prefixes := make([]netip.Prefix, 0, len(rawCIDRs))
	for _, rawCIDR := range rawCIDRs {
		prefix, err := parseGatewayPrefix(rawCIDR)
		if err != nil {
			return nil, fmt.Errorf("parse %s entry %q: %w", fieldName, rawCIDR, err)
		}
		prefixes = append(prefixes, prefix)
	}
	return prefixes, nil
}

func parseGatewayPrefix(rawCIDR string) (netip.Prefix, error) {
	value := strings.TrimSpace(rawCIDR)
	if value == "" {
		return netip.Prefix{}, fmt.Errorf("CIDR is empty")
	}

	prefix, err := netip.ParsePrefix(value)
	if err != nil {
		addr, addrErr := netip.ParseAddr(value)
		if addrErr != nil {
			return netip.Prefix{}, err
		}
		prefix = netip.PrefixFrom(addr, addr.BitLen())
	}

	prefix = prefix.Masked()
	if !prefix.Addr().Is4() {
		return netip.Prefix{}, fmt.Errorf("only IPv4 CIDRs are supported")
	}

	return prefix, nil
}
