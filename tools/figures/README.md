# Figures

`build.rb` draws the system figures in `docs/assets/figures/`: ten figures, each in a light and a dark variant, from one description per figure. It uses only the Ruby standard library. It is not part of the plugin and never runs on a student's computer.

    ruby tools/figures/build.rb [--png] [--only SLUG] [--out DIR] [--png-width PX] [--chrome PATH]

| Option | Effect |
| --- | --- |
| none | writes `<slug>-light.svg` and `<slug>-dark.svg` for every figure |
| `--png` | also renders each SVG to `png/<slug>-<theme>.png` with headless Chrome, 3840 pixels wide by default |
| `--only SLUG` | builds only the figures whose slug contains `SLUG` |
| `--out DIR` | writes somewhere other than `docs/assets/figures` |
| `--png-width PX` | sets the PNG width |
| `--chrome PATH` | names the Chrome to use; `REACH_FIGURES_CHROME` does the same |

It exits 0 when every file was written and 1 when a PNG could not be rendered.

## Layout

| Path | Holds |
| --- | --- |
| `kit.rb` | the two palettes, the icons and the drawing primitives (cards, pills, arrows, boundaries, the frosted Teach block) |
| `figures/NN_name.rb` | one figure each; `01_system.rb` also holds the shared legend, the Teach zones and the system body the poster reuses |
| `build.rb` | the command |

The SVGs are committed. The PNGs are build output: `docs/assets/figures/png/` is ignored by git, and the published copies are the assets of the `figures-1` release on GitHub, so no clone or install carries them.

## Changing a figure

Edit its file under `figures/`, run `ruby tools/figures/build.rb`, and commit the source together with both SVG variants. Every color comes from `THEMES` in `kit.rb`; a figure names a tone (`:student`, `:reach`, `:teach`, `:instructor`, `:ok`, `:stop`, `:soft`) and never a color, which is what keeps the two variants in step.

## What the figures may show of Teach

Teach is private. A figure draws it as the frosted block (`Canvas#frost`) and names only outcomes that this repository already publishes in `README.md`, `PRIVACY.md` or `specs/wire.yml`: that it checks the roster, seals and signs packages, runs hidden checks, signs receipts and answers hands. A figure never names a Teach class, table, file, setting or internal flow.
