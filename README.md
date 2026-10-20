# FONTS.R4X

`FONTS.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.1.8`
- Image target: `/R4OS/SOFTWARE/DESKTOP/FONTS.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.

FON import maps ANSI Windows-1252 and the explicit R4OS OEM CP437 policy to
Unicode before writing R4F. Other/ambiguous charsets fail visibly. Source
preview text is UTF-8; undefined 1252 slots are omitted. Static helpers reuse
R4STD's original mapping tables. Existing incorrectly mapped imports need
reimporting; the R4FONT dynamic decoder API remains unchanged.

Explicit `/TEXTTEST` reloads all 14 stock faces, checks real block/Euro rows,
imports three small independent FNT fixtures and compares their preview and
native glyph pixels. It removes its private installed font and exports the
successful result to `C:\TEMP\FONT08540.TXT`. `/SELFTEST` retains the optional
six historical local source-font test; its source files are not distributed.
The ordinary hosted GUI launch needs its desktop host. For an early headless
guest, Tests/TextConsumer builds FONTTEST.R4X as a console-only fixture with
IMAGE_SCOPE=none. It imports and calls this exact application's entry point;
it does not contain an alternate importer, preview or glyph test. Supply
/TEXTTEST or /SELFTEST explicitly. Product GUI behavior remains unchanged.


Input bounds and ownership (0.78.65)
-----------------------------------
R4FONT 0.2.2 reads the WOFF/WOFF2 size field only with at least 20 input bytes.
The FNT import helper transfers each bitmap to its owning list exactly once;
a later RasterGlyph allocation failure no longer frees it twice. FON/NE
header and resource offsets use checked, input-bounded arithmetic, including
resource alignment shifts. FONTS 0.1.4 embeds the corrected import helper.
No decoder API, interface layout or upstream library version changes.
The existing vendor byte manifest records the corrected local bridge.
Focused checks reuse the small R4F/FNT/FON/WOFF examples; no raster profiles
or long font runs are added.

GUI activity (0.81.18)
---------------------
Fonts uses the shared SDK EventLoop without application timers. Queued
input is handled before waiting; Close and wait failures unwind the source
font allocation. Input, font changes and resize trigger repaint; irrelevant
clicks retain the current frame. The app uses the full hosted client size.
The shared kernel activity wait still has its existing 250-ms safety slice
and wakes for other desktop activity; Fonts adds no periodic idle timer.
