//go:build linux
// +build linux

package internal

import (
	"context"
	"net/url"
	"time"

	"github.com/kelseyhightower/envconfig"
	"github.com/pkg/errors"
)

type Config struct {
	Name                   string            `default:"nse-ovs-gateway" desc:"Name of inline gateway NSE"`
	ListenOn               string            `default:"listen.on.sock" desc:"listen on socket" split_words:"true"`
	ConnectTo              url.URL           `default:"unix:///var/lib/networkservicemesh/nsm.io.sock" desc:"url to connect to" split_words:"true"`
	MaxTokenLifetime       time.Duration     `default:"10m" desc:"maximum lifetime of tokens" split_words:"true"`
	RegistryClientPolicies []string          `default:"" desc:"paths to files and directories that contain registry client policies" split_words:"true"`
	ServiceName            string            `default:"nse-ovs-gateway" desc:"name of provided network service" split_words:"true"`
	Labels                 map[string]string `default:"app:gateway" desc:"endpoint labels"`
	DownstreamLabels       map[string]string `default:"" desc:"labels used to select downstream endpoints; empty preserves the incoming request labels" split_words:"true"`
	GatewayRulesPath       string            `default:"/etc/nse-gateway/rules.yaml" desc:"path to the gateway rules YAML file" split_words:"true"`
	LogLevel               string            `default:"INFO" desc:"log level" split_words:"true"`
	OpenTelemetryEndpoint  string            `default:"otel-collector.observability.svc.cluster.local:4317" desc:"OpenTelemetry Collector Endpoint" split_words:"true"`
	MetricsExportInterval  time.Duration     `default:"10s" desc:"interval between metrics exports" split_words:"true"`
	PprofEnabled           bool              `default:"false" desc:"is pprof enabled" split_words:"true"`
	PprofListenOn          string            `default:"localhost:6060" desc:"pprof URL to ListenAndServe" split_words:"true"`

	gatewayPolicy *GatewayPolicy
}

func LoadConfig(_ context.Context) (*Config, error) {
	config := new(Config)

	if err := envconfig.Usage("nsm", config); err != nil {
		return nil, errors.Wrap(err, "cannot show usage of envconfig nsm")
	}

	if err := envconfig.Process("nsm", config); err != nil {
		return nil, errors.Wrap(err, "cannot process envconfig nsm")
	}

	if config.ServiceName == "" {
		config.ServiceName = config.Name
	}

	if config.Labels == nil {
		config.Labels = map[string]string{}
	}

	if len(config.DownstreamLabels) == 0 && len(config.Labels) > 0 {
		config.DownstreamLabels = make(map[string]string, len(config.Labels))
		for key, value := range config.Labels {
			config.DownstreamLabels[key] = value
		}
	}

	gatewayPolicy, err := LoadGatewayPolicyFromFile(config.GatewayRulesPath)
	if err != nil {
		return nil, errors.Wrapf(err, "cannot load gateway rules from %s", config.GatewayRulesPath)
	}
	config.gatewayPolicy = gatewayPolicy

	return config, nil
}

func (c *Config) GatewayPolicy() *GatewayPolicy {
	if c == nil {
		return nil
	}
	return c.gatewayPolicy
}
