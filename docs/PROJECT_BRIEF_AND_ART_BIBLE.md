# ISOMETRIC FANTASY MMORPG
## Combined Project Brief & Visual Art Bible

**Version:** 0.1  
**Status:** Preproduction — approved artistic direction; provisional technical specifications  
**Intended audience:** Human Creative Director, Claude Code / Codex, and development collaborators

---

# Part I — Project Brief

## 1. Project Vision

We are developing a persistent, multiplayer, 2D isometric fantasy RPG inspired by the classic experiences of **Ultima Online** and **The Realm Online**.

Our goal is to create a living fantasy world that encourages exploration, discovery, interaction, and meaningful character progression.

The game should capture the intimacy, detail, and sense of place of late-1990s MMORPGs while benefiting from modern development tools.

This is not intended to be a modern 3D MMORPG disguised as a retro game.

**The world should feel handcrafted, explorable, persistent, and alive.**

## 2. Technical Direction

- **Engine:** Godot 4
- **Primary language:** GDScript
- **Art production:** Blender, AI-assisted asset generation, ComfyUI where useful
- **Art format:** Pre-rendered 2D isometric sprites and tile assets
- **Networking:** Dedicated authoritative multiplayer server, introduced after the initial visual prototype
- **Persistence:** PostgreSQL is the initial candidate
- **Development:** Claude Code or Codex, with specialized agents introduced only when required
- **Source control:** GitHub

Favor modular systems, maintainable code, measurable performance, and working vertical slices over extensive theoretical architecture.

## 3. Gameplay Philosophy

The world should emphasize:

- Exploration and environmental discovery
- Meaningful interactions with objects, characters, and locations
- Persistent characters and possessions
- Social multiplayer experiences
- Equipment, skills, combat, and progression
- A world that feels inhabited rather than procedurally assembled without purpose

Specific combat, class, skill, crafting, and economic systems remain undecided. **Do not invent them as approved requirements.**

## 4. Initial Development Milestone

**Build a playable isometric visual laboratory.**

The first prototype should contain:

1. A small outdoor medieval fantasy environment.
2. One controllable player character.
3. Eight-direction movement and facing.
4. Correct isometric placement and depth sorting.
5. A camera that follows the player.
6. Trees, obstacles, a cottage, and environmental props.
7. Adjustable zoom for testing sprite readability.
8. A simple way to compare different native asset resolutions.

The purpose is to validate the visual experience before building MMO infrastructure.

Multiplayer, account systems, advanced combat, and large-world streaming are outside the first milestone.

## 5. Creative Authority

The human director approves the visual direction, major gameplay decisions, and architectural changes.

AI development agents must preserve approved decisions, work incrementally, and verify their implementations.

Do not substitute generic fantasy artwork or generic Godot demo aesthetics for the approved visual direction.

---

# Part II — Visual Art Bible

## 6. Artistic Identity

The game's defining visual reference is the **approved countryside homestead image**: a compact stone-and-timber cottage, small adventurer, lush green terrain, wooden fences, sheep, trees, flowers, dirt paths, and water.

A second reference depicting a **blacksmith's workshop** demonstrated promising consistency in this style.

**Primary influence:** Original *Ultima Online*.

**Secondary influence:** The material richness and pre-rendered texture treatment of classic *Diablo* games.

The overall aesthetic is **bright, natural, charming, richly detailed, and readable**.

Avoid making Diablo's dark, oppressive atmosphere the dominant artistic direction.

> **Reference handling:** Include the approved cottage and blacksmith images alongside this file when initializing an implementation agent. This document specifies the intended style but does not replace the visual references.

## 7. Rendering Style

- Late-1990s pre-rendered fantasy game artwork
- Fine pixel-level detailing
- Hand-finished appearance
- Subtle dark outlines and creases
- Varied, painterly material surfaces
- Compact character sprites
- Detailed but readable environments
- No modern photorealistic rendering
- No excessive bloom, glossy effects, or cinematic depth of field

The target is **not oversized, blocky pixel art**. Individual surface details can be quite fine.

## 8. Perspective and Scale

**Initial calibration targets — not final production commitments:**

| Property | Starting specification |
|---|---|
| Projection | Orthographic, 2:1 isometric diamond |
| Blender camera elevation | Approximately 30° above the horizontal |
| Camera azimuth | 45° relative to ground axes |
| Ground tile | Compare 64 × 32 and 96 × 48 pixels |
| Character height | Compare approximately 70 and 100 pixels |
| Directional animation | Eight facings |
| Display | Scalable viewport and independently readable UI |

Character proportions must remain grounded and compact relative to houses, trees, fences, and other world structures.

## 9. Materials and Textures

**Stone:** Irregular masonry, individually readable stone shapes, dark joints, subtle warm and cool variations.

**Wood:** Visible beams, grain, weathering, dark structural seams, moderate saturation.

**Roofs:** Individually readable tiles or shingles with natural variation and strong silhouettes.

**Foliage:** Dense clustered leaves with olive, moss, and yellow-green variations. Avoid smooth spherical tree canopies.

**Grass:** Mottled terrain with localized plants, patches of bare earth, flowers, and irregular growth.

**Metals:** Readable highlights, dark edges, worn surfaces, restrained specular response.

## 10. Lighting and Color

The default outdoor world uses pleasant natural daylight, baked directional shading, and readable shadows.

Primary color families:

- Olive and moss greens
- Warm earth browns
- Weathered timber
- Natural stone grays
- Muted brick reds
- Warm firelight
- Selective cool magical highlights

Strong local contrast helps distinguish objects without turning the entire scene dark.

## 11. Characters

Characters must be recognizable at native gameplay scale.

Important features include:

- Strong silhouettes
- Clearly differentiated clothing and equipment
- Readable weapons
- Consistent foot anchoring
- Eight-direction animation
- Proportions compatible with the approved environments

Our first illustrated player-character concept is inspired by **Melanie**: voluminous dark curly hair, a warm complexion, olive and brown adventurer equipment, and a sword crackling with blue magical energy.

Treat this as a **character concept**, not an animation-ready asset.

## 12. Magic and Effects

Magic should look energetic and satisfying without overwhelming the historical sprite aesthetic.

Our reference effect is a bright electric-blue sword with visible arcs of energy.

Where practical, weapon energy effects should be implemented separately from character animation so effects can be reused.

## 13. Production Pipeline

The proposed pipeline combines:

1. Approved AI-generated visual references.
2. Blender for controlled geometry, characters, camera angles, and animation.
3. ComfyUI or other image tools for stylistic treatments and suitable individual assets.
4. Image cleanup and sprite-sheet generation.
5. Godot for animation, world composition, and interaction.

A custom style LoRA may be explored later, but training is **not a prerequisite**.

All production assets must eventually meet standards for scale, perspective, transparency, pivots, collision footprints, and visual consistency.

## 14. Non-Negotiable Artistic Rules

- Maintain the approved compact isometric world scale.
- Preserve environmental readability.
- Keep the bright, lived-in countryside aesthetic as the baseline.
- Do not default to modern 3D fantasy graphics.
- Do not change character proportions between asset families.
- Do not introduce inconsistent camera angles.
- Do not confuse beautiful concept art with usable game assets.
- Test new assets at actual gameplay resolution.

**The objective is for every new asset and scene to look as though it belongs to the same finished game as our approved homestead reference.**

---

# Part III — Initial Handoff to Claude Code or Codex

These are our initial project specifications and approved visual references. Treat the art direction as established, but technical asset sizes as provisional.

**First assignment:** Design and implement our first playable Godot isometric visual prototype. Preserve the bright, compact, detailed Ultima Online–inspired visual direction. Do not expand into multiplayer or complex game systems yet.

Before building a large asset library, validate sprite readability at the proposed native resolutions. Clearly distinguish implemented and tested features from proposed work.
