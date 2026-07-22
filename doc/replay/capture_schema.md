# Capture stream schema v1 (`stab-*.jsonl`)

The replay rig (`tool/replay/`) consumes JSONL capture files recorded by a
consuming application at its stabilization input boundary. One JSON object
per line, discriminated by `t`. This document is the contract between the
consumer-side recorder and the rig — field renames are schema-version bumps
(`meta.v`), never silent.

Two families of records coexist in one file:

- **`obs` records** — the raw observation stream (every fresh block entering
  the consumer's dedup/merge stage, per capture). The rig's `freeze-report`
  and `ab-report` replay these through this package's own
  `stabilize()` funnel (`DefaultTrackedBlock` + the canonical `applyMerge`
  merger), so the measured semantics are the package's, on production input.
- **event records** — lifecycle events the consumer observed in its own
  integration (its provisional admission is consumer-driven and reuses the
  `isProvisional` fields this package's freeze path keys on). The rig's
  `live-report` aggregates these without replaying anything.

## Records

```jsonc
{"t":"meta", "v":1, "ts":<epochMs>, "note":"<free text>"}

{"t":"obs", "ts":..., "cap":<captureId>, "raw":<count before empty-text filter>,
 "blocks":[<block>, ...]}

// One non-frozen merge (consumer-side view; displacement of the merged rect
// center vs the existing block's).
{"t":"merge", "ts":..., "cap":..., "dx":.., "dy":.., "obsN":<post-merge>,
 "pconf":.., "tconf":.., "fromCache":bool}

// A merge that hit the provisional freeze path (#57 items 1-2).
{"t":"freeze", "ts":..., "cap":..., "heldText":"...", "freshText":"...",
 "differs":bool, "freshTconf":.., "heldTconf":.., "remaining":<post-decrement>,
 "obsN":<held count>}

// Consumer provisional admission lifecycle (#57 item 3).
{"t":"band_stamp", "ts":..., "cap":..., "fresh":<blockRef>, "existing":<blockRef>}
{"t":"band_decrement", "ts":..., "cap":..., "block":<blockRef>,
 "remaining":<post>, "expired":bool, "inBatch":bool}
{"t":"cluster_resolve", "ts":..., "cap":..., "noRivals":bool,
 "survivor":<blockRef|absent>, "evicted":[<blockRef>, ...]}
```

## `<block>` (obs entries)

Serialized via this package's `TrackedBlock`/`ObservableBlock` interfaces —
exactly the surface the engine can read — plus consumer extras.

| Field | Type | Interface member |
|---|---|---|
| `rect` | `[l,t,r,b]` doubles | `absoluteRect` |
| `otext` | string | `originalText` |
| `pconf` / `tconf` | double 0..1 | `positionConfidence` / `textConfidence` |
| `srcQ` | int | `sourceQuality` |
| `vr` | bool | `isViewportRelative` |
| `isc` | bool | `isInnerScrollerChild` |
| `iscTop` | double | `innerScrollerTop` |
| `hsc` | bool | `isHorizontalScrollChild` |
| `cid` | string or null | `containerId` |
| `sticky` | bool | `isFromStickyElement` |
| `sc` | `[scrollY, scrollX, hzScrollerIndex]` | `scrollContext` |
| `sf` | `[scrollY, scrollX, isIc, hzScrollerIndex]` | `stickyFallback` |
| `obsN` | int | `observationCount` |
| `prov` / `provN` | bool / int | `isProvisional` / `provisionalCapturesRemaining` |
| `cvotes` | `{ "<weight>": count }`, omitted when empty | `classificationVotes` |
| `carVotes` | `{ "<id>": count }`, omitted when empty | `carouselIdVotes` |
| `tvotes` | `{ key: {raw, score, best} }`, omitted when empty | `textVotes` |
| `gsig` / `gsigC` | int / bool | consumer extra (group signature) |
| `origin` | string | consumer extra (block origin) |
| `nav` | string | consumer extra (nav role) |

`<blockRef>` (event records) is the joining subset:
`{"otext":..., "rect":[l,t,r,b], "obsN":..., "provN":...}`.

## Loader notes (v1)

- Unknown fields are ignored (forward-compatible).
- `carVotes` absent → `DefaultTrackedBlock`'s phantom default `{-1: 1}`
  applies (the engine's "never seen in a carousel" sentinel).
- `tvotes` is **not** reconstructed by the v1 loader (fresh observations
  carry none in practice; the engine rebuilds votes during replay).
- Replay starts from an empty engine: streams captured mid-session with a
  pre-seeded consumer cache replay slightly colder than live (noted in
  reports as a caveat, not corrected).
