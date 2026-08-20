package service

import (
	"math"
	"path/filepath"
	"testing"

	"github.com/mhsanaei/3x-ui/v3/internal/database"
	"github.com/mhsanaei/3x-ui/v3/internal/database/model"
	"github.com/mhsanaei/3x-ui/v3/internal/xray"
)

// TestAddClientTraffic_AppliesInboundTrafficMultiplier locks in that an inbound
// with TrafficMultiplier=5 commits Xray's raw delta to client_traffics as 5x.
// A peer inbound with the default 1.0 must stay bit-exact: the multiplier
// must be looked up per-inbound, not applied panel-wide. This is the whole
// point of the feature — a 5x-marked entry on a premium VPS must not charge
// every other inbound's clients at the same rate.
func TestAddClientTraffic_AppliesInboundTrafficMultiplier(t *testing.T) {
	dbDir := t.TempDir()
	t.Setenv("XUI_DB_FOLDER", dbDir)
	if err := database.InitDB(filepath.Join(dbDir, "x-ui.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { _ = database.CloseDB() })

	db := database.GetDB()

	premium := &model.Inbound{
		UserId: 1, Tag: "premium-in", Enable: true, Port: 50001,
		Protocol: model.VLESS, TrafficMultiplier: 5.0,
	}
	if err := db.Create(premium).Error; err != nil {
		t.Fatalf("create premium inbound: %v", err)
	}
	budget := &model.Inbound{
		UserId: 1, Tag: "budget-in", Enable: true, Port: 50002,
		Protocol: model.VLESS, // default 1.0
	}
	if err := db.Create(budget).Error; err != nil {
		t.Fatalf("create budget inbound: %v", err)
	}

	// AddClientStat writes the inbound_id into client_traffics on insert; the
	// traffic loop reads it back to pick the multiplier.
	svc := InboundService{}
	if err := svc.AddClientStat(db, premium.Id, &model.Client{Email: "premium-user", ID: "u-1", Enable: true}); err != nil {
		t.Fatalf("AddClientStat premium: %v", err)
	}
	if err := svc.AddClientStat(db, budget.Id, &model.Client{Email: "budget-user", ID: "u-2", Enable: true}); err != nil {
		t.Fatalf("AddClientStat budget: %v", err)
	}

	if err := svc.addClientTraffic(db, []*xray.ClientTraffic{
		{Email: "premium-user", Up: 100, Down: 200},
		{Email: "budget-user", Up: 100, Down: 200},
	}); err != nil {
		t.Fatalf("addClientTraffic: %v", err)
	}

	var premiumStored xray.ClientTraffic
	if err := db.Model(xray.ClientTraffic{}).Where("email = ?", "premium-user").First(&premiumStored).Error; err != nil {
		t.Fatalf("reload premium row: %v", err)
	}
	if premiumStored.Up != 500 || premiumStored.Down != 1000 {
		t.Errorf("premium multiplier not applied: up=%d down=%d, want 500/1000 (5x of 100/200)", premiumStored.Up, premiumStored.Down)
	}

	var budgetStored xray.ClientTraffic
	if err := db.Model(xray.ClientTraffic{}).Where("email = ?", "budget-user").First(&budgetStored).Error; err != nil {
		t.Fatalf("reload budget row: %v", err)
	}
	if budgetStored.Up != 100 || budgetStored.Down != 200 {
		t.Errorf("budget inbound contaminated by sibling multiplier: up=%d down=%d, want 100/200 (1.0)", budgetStored.Up, budgetStored.Down)
	}
}

// TestAddClientTraffic_MissingInboundFallsBackToOne covers the stale
// client_traffics.inbound_id case (the inbound was deleted but the email row
// survives). The traffic loop must still apply 1.0 — never panic on a missing
// map key, never inherit a sibling's multiplier.
func TestAddClientTraffic_MissingInboundFallsBackToOne(t *testing.T) {
	dbDir := t.TempDir()
	t.Setenv("XUI_DB_FOLDER", dbDir)
	if err := database.InitDB(filepath.Join(dbDir, "x-ui.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { _ = database.CloseDB() })

	db := database.GetDB()

	if err := db.Create(&model.Inbound{
		UserId: 1, Tag: "only-in", Enable: true, Port: 50003, Protocol: model.VLESS, TrafficMultiplier: 9.0,
	}).Error; err != nil {
		t.Fatalf("create inbound: %v", err)
	}

	// client_traffics row pointing at a now-nonexistent inbound id; no live
	// inbound at id=42 exists, so the loop's multiplier lookup must default.
	if err := db.Create(&xray.ClientTraffic{InboundId: 42, Email: "orphan", Enable: true}).Error; err != nil {
		t.Fatalf("create orphan row: %v", err)
	}

	svc := InboundService{}
	if err := svc.addClientTraffic(db, []*xray.ClientTraffic{{Email: "orphan", Up: 100, Down: 50}}); err != nil {
		t.Fatalf("addClientTraffic: %v", err)
	}

	var stored xray.ClientTraffic
	if err := db.Model(xray.ClientTraffic{}).Where("email = ?", "orphan").First(&stored).Error; err != nil {
		t.Fatalf("reload orphan row: %v", err)
	}
	if stored.Up != 100 || stored.Down != 50 {
		t.Errorf("orphan inbound did not fall back to 1.0: up=%d down=%d, want 100/50", stored.Up, stored.Down)
	}
}

// TestAddInboundTraffic_AppliesInboundTrafficMultiplier mirrors the client
// test for the per-inbound up/down counters. Both counters go through the same
// multiplier because the quota check and the dashboard use the inbound's own
// up/down as an aggregate signal; if only the client side were scaled, an
// operator comparing inbound total vs sum-of-clients would see phantom leakage.
func TestAddInboundTraffic_AppliesInboundTrafficMultiplier(t *testing.T) {
	dbDir := t.TempDir()
	t.Setenv("XUI_DB_FOLDER", dbDir)
	if err := database.InitDB(filepath.Join(dbDir, "x-ui.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	t.Cleanup(func() { _ = database.CloseDB() })

	db := database.GetDB()

	premium := &model.Inbound{
		UserId: 1, Tag: "premium-agg", Enable: true, Port: 50101,
		Protocol: model.VLESS, TrafficMultiplier: 3.0,
	}
	budget := &model.Inbound{
		UserId: 1, Tag: "budget-agg", Enable: true, Port: 50102, Protocol: model.VLESS,
	}
	if err := db.Create(premium).Error; err != nil {
		t.Fatalf("create premium: %v", err)
	}
	if err := db.Create(budget).Error; err != nil {
		t.Fatalf("create budget: %v", err)
	}

	svc := InboundService{}
	if err := svc.addInboundTraffic(db, []*xray.Traffic{
		{IsInbound: true, Tag: "premium-agg", Up: 1000, Down: 2000},
		{IsInbound: true, Tag: "budget-agg", Up: 1000, Down: 2000},
	}); err != nil {
		t.Fatalf("addInboundTraffic: %v", err)
	}

	var p, b model.Inbound
	if err := db.Where("tag = ?", "premium-agg").First(&p).Error; err != nil {
		t.Fatalf("reload premium: %v", err)
	}
	if p.Up != 3000 || p.Down != 6000 {
		t.Errorf("premium inbound aggregate not scaled: up=%d down=%d, want 3000/6000", p.Up, p.Down)
	}
	if err := db.Where("tag = ?", "budget-agg").First(&b).Error; err != nil {
		t.Fatalf("reload budget: %v", err)
	}
	if b.Up != 1000 || b.Down != 2000 {
		t.Errorf("budget inbound aggregate changed: up=%d down=%d, want 1000/2000", b.Up, b.Down)
	}
}

// TestNormalizeTrafficMultiplier pins down the safety clamp on every read/write
// path. A 0 (would zero out traffic on the next poll), a negative value
// (would invert) and NaN/Inf (would propagate to a JSON marshal panic on
// some backends) must all be caught here, not at the call site. The NaN/Inf
// checks have to come first inside NormalizeTrafficMultiplier because every
// finite comparison against NaN returns false — without that ordering, a
// NaN row would silently bypass the clamp.
func TestNormalizeTrafficMultiplier(t *testing.T) {
	cases := []struct {
		name string
		in   float64
		want float64
	}{
		{"zero operator typo", 0, 1.0},
		{"negative would invert", -1, 1.0},
		{"below the 0.1 floor", 0.05, 1.0},
		{"lower edge", 0.1, 0.1},
		{"default identity", 1.0, 1.0},
		{"common premium rate", 5.0, 5.0},
		{"upper edge", 100, 100},
		{"above the 100 ceiling", 100.01, 1.0},
		{"positive infinity", math.Inf(1), 1.0},
		{"negative infinity", math.Inf(-1), 1.0},
		{"NaN propagates", math.NaN(), 1.0},
	}
	for _, c := range cases {
		if got := model.NormalizeTrafficMultiplier(c.in); got != c.want {
			t.Errorf("%s: NormalizeTrafficMultiplier(%v) = %v, want %v", c.name, c.in, got, c.want)
		}
	}
}

// TestScaledTrafficBytes pins the rounding rules. The traffic counter is
// int64 and downstream consumers compare against the int64 TotalGB quota, so
// the float→int cast must round half-away-from-zero, not truncate — a client
// at 0.5 bytes × 5 would otherwise accumulate a slowly growing deficit and
// appear not to consume quota. Zero passes through; negatives (not produced
// today but reserved for future reset paths) pass through untouched.
func TestScaledTrafficBytes(t *testing.T) {
	cases := []struct {
		name       string
		raw        int64
		multiplier float64
		want       int64
	}{
		{"zero raw short-circuits", 0, 5.0, 0},
		{"1x identity", 1024, 1.0, 1024},
		{"5x rounding up", 100, 5.0, 500},
		{"0.5 floor guard identity", 1024, 0.1, 102},
		{"negative passes through", -100, 5.0, -100},
		{"NaN multiplier falls back to 1", 1000, math.NaN(), 1000},
		{"Inf multiplier falls back to 1", 1000, math.Inf(1), 1000},
		{"out-of-range multiplier falls back to 1", 1000, 9999, 1000},
	}
	for _, c := range cases {
		if got := model.ScaledTrafficBytes(c.raw, c.multiplier); got != c.want {
			t.Errorf("%s: ScaledTrafficBytes(%d, %v) = %d, want %d", c.name, c.raw, c.multiplier, got, c.want)
		}
	}
}
