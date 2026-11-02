package vnf

import (
	"context"
	"fmt"

	"nse-ovs-gateway/internal/processor"
)

type Service struct {
	dataplane Dataplane
	handler   Handler
}

func New(gatewayRulesPath string) processor.FlowSetup {
	return NewService(
		NewPassthroughDataplane(),
		NewPhasedHandler(
			DefaultRuleInstaller(gatewayRulesPath),
			DefaultRuntimeHook(),
			DefaultCleanupHook(),
		),
	)
}

func NewService(dataplane Dataplane, handler Handler) processor.FlowSetup {
	return &Service{
		dataplane: dataplane,
		handler:   handler,
	}
}

func (s *Service) Setup(ctx context.Context, runtime *processor.Runtime) (processor.Session, error) {
	if s == nil {
		return nil, fmt.Errorf("service is required")
	}

	sessionCtx, err := newSessionContext(runtime)
	if err != nil {
		return nil, err
	}

	dataplane := s.dataplane
	if dataplane == nil {
		dataplane = NewPassthroughDataplane()
	}

	handler := s.handler
	if handler == nil {
		handler = NewNoopHandler()
	}

	dataplaneSession, err := dataplane.Connect(ctx, sessionCtx)
	if err != nil {
		return nil, err
	}

	handlerSession, err := handler.Configure(ctx, sessionCtx)
	if err != nil {
		if dataplaneSession != nil {
			_ = dataplaneSession.Close(ctx)
		}
		return nil, err
	}

	// Close the handler before tearing down the dataplane.
	return processor.JoinSessions(dataplaneSession, handlerSession), nil
}
