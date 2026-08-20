# Traffic Multiplier — Install / Upgrade Guide

This build adds a per-inbound **traffic multiplier** to the sub-node 3x-ui.
It scales every byte that Xray reports for an inbound (and every byte
credited to the clients attached to it) before the bytes are written to the
local `client_traffics` / `inbounds` tables. The scaled values are what
flow out to the master 3x-ui over the existing node-sync path, so a single
quota check on the master panel covers all your sub-nodes without any
master-side changes.

---

## What you get

| Mode | Behaviour |
|---|---|
| `1.0` (default) | Identical to a stock build — every byte is recorded byte-for-byte. Use this on nodes that charge you no premium. |
| `5.0` (premium VPS) | Every real byte counts as 5. A client with a 100 GB quota appears to consume 20 GB. |
| `0.5` (cheap VPS) | Counts half. Useful if you ever want to discount a node. |

Range: **`0.1` – `100`**. Out-of-range values fall back to `1.0` at write
time (no panic, no inversion), and a value stored as `NaN` / `Inf` (a
corrupted row from a future bug) is treated the same way.

The multiplier applies to **both directions** (`up` and `down`) and to
**both the per-client counter** (`client_traffics.up/down`) and the
**per-inbound aggregate** (`inbounds.up/down`). The per-inbound up/down
is what the subscription page and node-sync use, so the master panel sees
scaled numbers everywhere without knowing a multiplier exists.

---

## A. Fresh install

1. Install 3x-ui as usual:

   ```bash
   bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
   ```

2. Start the panel. The schema migration runs on first boot — the
   `traffic_multiplier` column is added to `inbounds` with a default of
   `1.0`, so every existing row keeps its existing semantics.

3. Open the panel, create or edit an inbound. The new **Traffic
   multiplier** field is on the **Basic** tab, just under the periodic
   traffic reset settings. Enter `5.0` (or whatever) and save.

4. The next traffic poll (within ~5 seconds) starts recording scaled
   bytes. No restart needed; no traffic loss.

---

## B. In-place upgrade (preserves users and traffic history)

This is the path you want if your nodes are already serving clients.

### B.1 — Read the README prerequisites

- Back up `/etc/x-ui/` and `/var/lib/x-ui/` (or wherever your DB lives).
- Stop the panel cleanly: `x-ui stop`. **Do not** kill the Xray process —
  it keeps serving in-flight traffic until the new panel boots.

### B.2 — Upgrade

```bash
x-ui stop
# replace the binary (release tarball, package manager, etc.)
# the new binary carries the updated 3x-ui panel
x-ui start
```

What happens on `x-ui start`:

- The `initModels()` migration runs `AutoMigrate` on every model. For
  `inbounds`, that adds the `traffic_multiplier` column with a default of
  `1.0`. SQLite backfills every existing row with `1.0` (Postgres uses
  its native default), so **every existing inbound keeps its current
  behaviour** — historical up/down numbers do not change.
- The `default:1.0` means you can upgrade a busy panel with zero
  configuration work. The master node continues to receive the same
  scaled-by-1.0 (i.e. unchanged) values during the rollout.
- The Xray stats counters are stored in `client_traffics`, which already
  has the `inbound_id` we need to look up the multiplier. No schema
  changes touch existing client rows.

### B.3 — Configure multipliers on the nodes that need them

Open the panel on each sub-node and:

1. Edit the inbound you want to mark as premium.
2. Set **Traffic multiplier** to `5.0` (or whatever).
3. Save.

The new multiplier is read on the next traffic poll (~5 s). From that
poll onward, every byte Xray reports for that inbound is multiplied
**before** it is written to `client_traffics` / `inbounds.up/down`. The
master 3x-ui, which already polls these numbers, now sees 5x values and
triggers quota exhaustion after `quota / 5` actual traffic.

### B.4 — Verify on the master panel

On the master panel, open a client's stats. You should see the per-node
traffic match what the sub-node is reporting. If you set the multiplier
on the sub-node, the master's view of that inbound's traffic should be
5x the value the user thinks they consumed.

---

## C. Important behaviours to know

### Historical data is **not** retroactively re-scaled

If a user consumed 30 GB at `1.0` and you later set the multiplier to
`5.0`, those 30 GB stay 30 GB on disk. Only **new** traffic, from the
poll after the multiplier change, is scaled. This is intentional —
retroactively re-scaling would make the master panel claim the user
consumed 150 GB and lock them out.

If you want to reset a client's counters to start clean with the new
multiplier, use the existing **Reset traffic** button on the client's
detail page.

### Multipliers are per-inbound, not per-client

A user attached to two inbounds with different multipliers has a single
`client_traffic` row keyed by `email`, and the row carries the
`inbound_id` it was first attached to. The traffic path multiplies by
that inbound's multiplier. If your clients are attached to multiple
inbounds, this matches the existing "attribute traffic to one inbound"
behaviour — the same convention the rest of the traffic pipeline uses.
If you need different multipliers per client, you need different
inbounds with disjoint client sets.

### Xray restart does not lose data

The multiplier is stored in the `inbounds` row, not in Xray's runtime
state. When Xray restarts (config reload, crash, upgrade), the next
poll reads the multiplier from the DB and resumes scaling. There is no
in-memory counter to lose.

### Setting it to `1.0` restores legacy behaviour

A panel upgraded with this build and configured with `1.0` everywhere is
bit-identical to a stock build on the wire. The existing
`clamped_add` arithmetic on `up` / `down` is unchanged; the only new
step is the multiplier multiply, which is `1.0` and gets folded out by
the Go compiler as a no-op in `ScaledTrafficBytes`.

### Clamping safety

Out-of-range multipliers (`0`, negative, `NaN`, `Inf`, `>100`) fall back
to `1.0` in `model.NormalizeTrafficMultiplier`. This is enforced at
every read in the traffic path so a typo or a corrupted row cannot zero
out or invert the panel's traffic counters. The frontend's zod schema
(`InboundDbFieldsSchema.trafficMultiplier`) also rejects out-of-range
values before they leave the modal.

---

## D. Rollback

If you need to undo the upgrade:

```bash
x-ui stop
# restore the previous binary
x-ui start
```

The old binary does not know about `traffic_multiplier`, but GORM's
`AutoMigrate` only adds columns — it never removes them. The old
binary will simply ignore the column. **All traffic stored during the
upgrade remains compatible**, because the multiplier is applied at
write time, so every value already in the DB is the *result* of
applying the multiplier, not the raw Xray delta. The old binary will
read those values as it always has.

If you want to drop the column (not required), run:

```sql
ALTER TABLE inbounds DROP COLUMN traffic_multiplier;
```

after rolling back.

---

## E. Quick reference

| Question | Answer |
|---|---|
| Master panel needs an update? | No. Master is multiplier-unaware. |
| Existing traffic records changed? | No. Migration is additive. |
| User data lost on upgrade? | No. Schema change is additive. |
| Xray needs to be reinstalled? | No. The change is in the panel. |
| Restart of panel needed? | Only the upgrade itself, not for each multiplier change. |
| Change takes effect when? | Next traffic poll after saving (≤5 s). |
| Per-client multiplier? | No — per-inbound only. Use separate inbounds for separate rates. |
| Out-of-range value? | Falls back to 1.0 with no error. |
