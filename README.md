# Mini Geo Stickers

Mini Geo Stickers is a small collection of geometric SVG stickers, with a PowerShell build script that exports selected source artwork into ready-to-use SVG and PNG files.

The repository currently includes twisty-puzzle stickers such as 2x2, 3x3, 4x4, 5x5, Megaminx, Mirror Cube, Pyraminx, and Skewb, plus logo-style stickers such as Arch Linux and Cosmic Desktop.

## Repository Layout

```text
.
|-- Build-Images.ps1          # Export script for generated images
|-- common/                   # Shared SVG definitions, such as gradients
|-- cube/                     # Puzzle sticker source SVGs
|-- logo/                     # Logo and desktop sticker source SVGs
`-- output/                   # Generated files, ignored by git
```

## Requirements

- PowerShell 7 or Windows PowerShell
- ImageMagick, available as the `magick` command, for PNG output

The script always writes SVG output. ImageMagick is only required for source files that request PNG output with `<extra-format>PNG</extra-format>`.

## Build

From the repository root, run:

```powershell
./Build-Images.ps1
```

The script scans the `cube/` and `logo/` folders for SVG files that opt in with:

```xml
<metadata>
  <output>true</output>
</metadata>
```

Generated files are written to `output/` while preserving the source folder structure. For example, `cube/3x3.svg` is exported to `output/cube/3x3.svg`, and if PNG output is requested, also to `output/cube/3x3.png`.

## SVG Source Conventions

Source SVGs can use metadata to control export behavior:

```xml
<metadata>
  <title>3x3 Cube Sticker</title>
  <output>true</output>
  <extra-format>PNG</extra-format>
</metadata>
```

Supported metadata:

- `<output>true</output>` marks a source SVG for export.
- `<extra-format>PNG</extra-format>` also exports a PNG copy.
- `<variant-style>name-a, name-b</variant-style>` exports one file per listed style variant.

The build script also prepares standalone output files by:

- inlining external SVG paint servers such as shared gradients from `common/common-defs.svg`
- inlining linked SVG images such as `logo/GAN.svg`
- inlining XML stylesheet references such as `cube/standard-cube-colors.css`
- resolving CSS custom properties like `var(--red)` into concrete values
- removing source-only metadata from generated SVGs

## License

This project is licensed under the MIT License. See `LICENSE` for details.
