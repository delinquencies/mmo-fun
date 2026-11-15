# Agent notes

- Read `docs/PROJECT_BRIEF_AND_ART_BIBLE.md` and look at `docs/reference/`
  before changing any art. The art direction is approved; asset sizes are
  provisional.
- Current status, open decisions and next steps: `docs/PROTOTYPE_STATUS.md`.
- The camera and scale contract lives in two places that must stay in sync:
  `tools/forge/render.py` and `game/scripts/core/iso.gd`.
- Simulation (`game/scripts/sim/`) holds no rendering state. Views
  (`game/scripts/view/`) read it.
- Never invent combat, class, crafting or economy systems as requirements.
- After changing forge models, re-run `python3 tools/forge/build.py` and
  verify with the headless screenshot mode (see README).
- Project state and known issues: `PROJECT_STATE.md`. Interaction/item
  contract: `docs/INTERACTION_SYSTEMS.md`.
- All item and world-object changes go through `InteractionSystem.submit()`
  with an `InteractionCommand`. UI and views must never mutate `ItemStore`
  or `Interactable` state directly.
- Run `godot --headless --path game --script res://tests/run_tests.gd` after
  touching anything in `game/scripts/sim/`.
- Multiplayer (Slice 003): the server's `WorldSim` is the only authority
  online. Clients send movement *intent* and `InteractionCommand`s only;
  replicas change only via server messages, plus movement prediction that the
  server corrects. Protocol: `game/scripts/net/protocol.gd` and
  `docs/NETWORK_PROTOCOL.md`; keep the two in sync and bump
  `Protocol.VERSION` on incompatible changes.
- Run `godot --headless --path game --script res://tests/mp_tests.gd` after
  touching `game/scripts/net/` or anything the server uses.
- Persistence (Slice 004): item and permanent-object changes must pass the
  durable gate (`ItemTransferService.persist`, `InteractionSystem.persist_world`)
  BEFORE memory changes. Never re-send a commit whose outcome is unknown; resolve
  it by `op_id`. Schema changes go in a new `db/migrations/NNN_*.sql`. Never log
  or commit passwords, hashes, tokens or `.dev/` secrets. Docs: `docs/PERSISTENCE.md`.
- Run `tests/keeper/run.sh` and `tests/persist/run.sh` after touching
  `tools/keeper/`, `db/`, or server persistence code.
