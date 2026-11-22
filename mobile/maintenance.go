package mobile

import (
	"context"
	"time"
)

// Maintenance groups cancelable work for a mobile background task.
type Maintenance struct {
	ctx    context.Context
	cancel context.CancelFunc
}

func NewMaintenance() *Maintenance {
	ctx, cancel := context.WithCancel(context.Background())
	return &Maintenance{ctx: ctx, cancel: cancel}
}

func (m *Maintenance) Cancel() { m.cancel() }

func (m *Maintenance) RefreshSubscriptions(raw string) (string, error) {
	return refreshDueSubscriptions(m.ctx, raw)
}

func (m *Maintenance) UpdateGeo() error {
	return updateGeo(m.ctx, true)
}

func refreshDueSubscriptions(parent context.Context, raw string) (string, error) {
	ctx, cancel := context.WithTimeout(parent, 45*time.Second)
	defer cancel()
	return autoRefreshSubscriptions(ctx, raw, time.Now(), func(ctx context.Context, url string) (string, error) {
		return fetchSubscriptionContext(ctx, subscriptionClient, url)
	})
}
