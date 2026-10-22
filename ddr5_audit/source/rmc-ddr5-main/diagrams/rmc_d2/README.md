# RMC v1.9.8 — D2 Architecture

Source: base python(excalidraw) doc, org arch (post-drift-correction).

Render:
```
d2 rmc_architecture.d2 rmc_architecture.svg
```
or paste into d2 playground: https://play.d2lang.com

Domains: AXI -> CIF -> MC Core -> Scheduler -> FSM Tables -> Maintenance Engine -> DFI/PHY.
Scheduler = read-only consumer. Maintenance Engine = 6 sub-FSM. Rules block = invariants.
