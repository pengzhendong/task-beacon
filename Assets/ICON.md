# TaskBeacon icon

Final design: two white task cards, a graphite command prompt, and a sage-green progress bar.

- `TaskBeacon.source.png`: approved original raster artwork, generated with the built-in ImageGen tool.
- `TaskBeacon.png`: production 1024×1024 sRGB PNG with transparent corners.
- `../Resources/TaskBeacon.icns`: macOS icon bundle with 16–1024 px representations.
- `../Resources/TaskBeaconStatus.png`: menu-bar-only monochrome PNG; white artwork surfaces are real alpha and all retained non-white details are pure white.
- `../scripts/generate-icons.sh`: repeatable export (`make icons`).

The exporter preserves the approved artwork, resizes it and applies a continuous rounded-square alpha mask for macOS packaging. It does not redraw the cards or progress bar. Earlier Icon Composer/vector explorations are not the source for this final icon.

The menu-bar variant is derived from the same approved artwork by `scripts/export-status-icon.swift`. White card surfaces become transparent; detached shadow fragments are removed, and the retained command mark and progress fill become pure white. Empty margins are trimmed for legibility at 22 pt, retaining the high-resolution source pixels. The Finder/application icon stays unchanged. An ImageGen transparency attempt returned an opaque checkerboard and was rejected; the shipped status asset uses a deterministic alpha mask, not that generated image.

## Generation prompt

Use case: logo-brand.
Create ONE original polished macOS application icon for TaskBeacon, an unobtrusive desktop monitor for AI agents and long-running tasks. This is an app icon design, not a screenshot, advertising scene or a design board.
Art direction: thoughtful native Mac utility, a memorable single unified silhouette with restrained dimensional craftsmanship. Soft satin surfaces, subtle soft light, shallow depth, crisp clean curves, generous optical spacing. Simple composition, sophisticated proportions, contemporary and calm. Avoid thick extrusions, generic liquid-glass outlines, metallic bevel rims or plastic pill-button appearance.
Canvas: square 1024x1024. White macOS rounded-square tile centered, occupying about 84% of the canvas, on an almost-white neutral surround; artwork centered in the tile with balanced margins. Very subtle natural shadow around the tile. The main mark occupies about 65% of the tile.
Palette: white and soft graphite with at most ONE desaturated blue-gray hue. No yellow, orange, multicolor gradients, vivid blue, rainbow or neon. No floating balls, separate stars, sparkle symbols, ring-plus-star compositions, generic charts, decorative badges or text labels. This must be a distinct coherent designed object. No existing app logos.
Subject: an elegant small stack of exactly two task cards as ONE coherent icon. A pale gray rear card offset subtly upward-left behind a larger off-white front card. Rounded corners with very subtle paper-like thickness, gentle cast shadow, near-frontal view. On the front card: a strong compact graphite command-prompt chevron near the upper left and one carefully proportioned recessed horizontal progress slot lower down, two-thirds filled with muted slate-blue and the remainder pale gray. Nothing else: no row lists, checkmarks, circles, robot, decorative text or badge. The card stack has beautiful bold silhouette and relaxed spacing. Restrained depth: looks like a finished native Mac productivity app, not an outlined UI component or stock clipart.

## Color edit prompt

Use case: precise-object-edit.
Image 1 is the edit target: the approved TaskBeacon macOS app icon showing two softly dimensional white task cards, a graphite command chevron and one inset progress bar.
Make ONE change only: recolor the FILLED SECTION of the horizontal progress bar to muted sage green, approximately #7B9785, calm gray-green, medium lightness and low saturation.
Preserve its existing surface shading, highlight, satin texture, rounded shape and exact completion length. Preserve the white/light-gray unfilled section.
Everything else must remain identical: the graphite command chevron, both white cards, card overlap, angle, outer white macOS icon tile, scale, white surround, soft shadows, all positions, boundaries and textures. Do not redraw, restyle or redesign any object. No tint elsewhere. No yellow, floating spheres, extra features, text, borders or added marks. Return one complete square app icon matching the reference framing.
