package inline

import "nse-ovs-gateway/internal/processor"

type flowBoundSession struct {
	processor.Session
	connectionID string
	ingress      string
	egress       string
}

func bindProcessorSession(flow *processor.Flow, session processor.Session) processor.Session {
	if flow == nil || session == nil {
		return session
	}

	return &flowBoundSession{
		Session:      session,
		connectionID: flow.ConnectionID,
		ingress:      flow.IngressInterface,
		egress:       flow.EgressInterface,
	}
}

func sessionMatchesFlow(session processor.Session, flow *processor.Flow) bool {
	if flow == nil || session == nil {
		return false
	}

	boundSession, ok := session.(*flowBoundSession)
	if !ok {
		return false
	}

	return boundSession.connectionID == flow.ConnectionID &&
		boundSession.ingress == flow.IngressInterface &&
		boundSession.egress == flow.EgressInterface
}
