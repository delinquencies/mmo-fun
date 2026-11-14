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
