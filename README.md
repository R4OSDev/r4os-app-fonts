# FONTS.R4X

`FONTS.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.1.4`
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
