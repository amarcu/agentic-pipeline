# Lantern Deep art bible — worked example

Lantern Deep is a fictional game, written here so the skill has a complete bible to review
against. Copy the section shape for a real project's `agent/ART.md` and replace every rule.

## Identity, in one sentence

One small diver with one warm lantern, alone in cold water that is full of things much larger
than the diver. Every image has to read as that sentence before it reads as anything else.

## Palette

- **Water:** three blues only, from `#061A2B` (deep) through `#0E3A5C` to `#1F6E8C` (near the
  surface). The background never uses a hue outside this ramp.
- **Lantern:** one warm colour, `#FFB347`, and its glow. It is the only warm hue on screen.
- **Danger:** `#E0344A`, used for nothing else. A red that is not a threat is a bug.
- **Neutrals:** greys carry a little of the water's blue. No pure grey, no pure black.

## Diver rules

- The diver is at most 1/12 of the screen height at the default zoom.
- The lantern glow is always visible, in every frame, including menus that show the diver.
- The diver's silhouette has exactly one asymmetric feature (the lantern arm), so its facing is
  readable without colour.

## Creature rules

- A creature is drawn in the water ramp, one step lighter than the water behind it.
- Only the part of a creature that can hurt the diver may use the danger colour.
- No creature has a light source warmer than the lantern.

## Readability tests (judged at half size, 480 px wide)

1. **The lantern test.** Squint at the frame. The brightest warm point is the diver's lantern.
2. **The threat test.** Every danger-coloured shape in the frame is something that can hurt the
   diver within the next two seconds.

## Capsule rules

- The store capsule shows one diver, one lantern and one creature at least eight times the
  diver's size. Nothing else.
- The title sits in the top third, in the lantern colour, on water from the deep end of the ramp.

## Banned

- A second warm light source.
- Gradients that leave the water ramp.
- Text over the diver.
- Screen shake as the only signal of damage.
