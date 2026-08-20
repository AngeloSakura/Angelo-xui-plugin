package service

import (
	"testing"

	"github.com/mhsanaei/3x-ui/v3/internal/database"
	"github.com/mhsanaei/3x-ui/v3/internal/database/model"
)

// The inbound update path loads the row, copies a hand-written allowlist of
// fields from the request body into the loaded row, then `tx.Save`s the row.
// traffic_multiplier was missing from that allowlist, so every save round-trip
// silently rewrote the column back to 1.0 regardless of what the UI sent.
func TestUpdateInbound_PersistsTrafficMultiplier(t *testing.T) {
	setupConflictDB(t)
	seedInboundConflict(t, "in-31400-tcp", "0.0.0.0", 31400, model.VLESS,
		`{"network":"tcp"}`, `{"clients":[]}`)

	var existing model.Inbound
	if err := database.GetDB().Where("tag = ?", "in-31400-tcp").First(&existing).Error; err != nil {
		t.Fatalf("read seeded row: %v", err)
	}
	if existing.TrafficMultiplier != 1.0 {
		t.Fatalf("seed default = %v, want 1.0", existing.TrafficMultiplier)
	}

	svc := &InboundService{}
	update := existing
	update.Port = existing.Port
	update.TrafficMultiplier = 2.5
	if _, _, err := svc.UpdateInbound(&update); err != nil {
		t.Fatalf("UpdateInbound: %v", err)
	}

	var reloaded model.Inbound
	if err := database.GetDB().First(&reloaded, existing.Id).Error; err != nil {
		t.Fatalf("reload: %v", err)
	}
	if reloaded.TrafficMultiplier != 2.5 {
		t.Fatalf("persisted TrafficMultiplier = %v, want 2.5", reloaded.TrafficMultiplier)
	}
}