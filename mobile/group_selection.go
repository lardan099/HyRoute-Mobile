package mobile

import (
	"context"
	"slices"
	"sync"
	"time"

	"github.com/xtls/xray-core/app/observatory"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/extension"
)

// Allow the default three-second probe to report before routing initial flows.
const initialGroupCheckTimeout = 3500 * time.Millisecond

type initialGroupCheck struct {
	wait     sync.Once
	ctx      context.Context
	observer extension.Observatory
	primary  []string
}

func (r *vpnFlowRouter) prepareGroupChecks(ctx context.Context) error {
	if len(r.configuration.initialGroupChecks) == 0 {
		return nil
	}
	return core.RequireFeatures(ctx, func(observer extension.Observatory) error {
		r.groupChecks = make(map[string]*initialGroupCheck, len(r.configuration.initialGroupChecks))
		for tag, primary := range r.configuration.initialGroupChecks {
			r.groupChecks[tag] = &initialGroupCheck{ctx: ctx, observer: observer, primary: primary}
		}
		return nil
	})
}

func (c *initialGroupCheck) awaitResults() {
	ctx, cancel := context.WithTimeout(c.ctx, initialGroupCheckTimeout)
	defer cancel()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		report, err := c.observer.GetObservation(ctx)
		if err != nil {
			return
		}
		result, ok := report.(*observatory.ObservationResult)
		if !ok {
			return
		}
		count := 0
		for _, status := range result.Status {
			if slices.Contains(c.primary, status.OutboundTag) {
				count++
			}
		}
		if count == len(c.primary) {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
