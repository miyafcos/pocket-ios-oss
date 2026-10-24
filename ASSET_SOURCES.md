# Asset sources

All bundled PNGs were decoded and checked for embedded metadata. This is separate from checking their origin. The source contains no captured screenshots or user conversation fixtures.

## Reproducible artwork

With Python and Pillow available, generate into a **new** directory:

```sh
python scripts/generate_public_assets.py new-asset-output
```

The command creates eighteen PNGs and refuses to overwrite an existing directory. It does not modify the asset catalog or automatically install any dependency.

- Twelve template images (`AgentClaude`, `AgentCodex`, `AgentGrok`, `AgentUnknown`, at three scales) reproduce the project's original drawing functions. Their pixels were matched in full to the included assets. These are simple drawn burst, hexagon, crossed-stroke and dot symbols, not imported vendor artwork.
- Three app images (`AppClaude`, `AppCodex`, `AppHybrid`) use independent generic terminal geometry created for this public snapshot. The old images are not distributed.
- Three `HarnessAvatar` images use independently drawn robot geometry, not Hermes artwork.

Pillow and image-codec versions can change compressed bytes; compare decoded RGBA pixels as well as dimensions rather than relying only on PNG file hashes.

## Custom symbol

`Sources/Assets.xcassets/skill.swordshield.symbolset/skill.swordshield.svg` retains the Xcode symbol document guides, with independent shield and straight-sword paths in its three weight groups. The complete vector source is included. No prior symbol paths are distributed.

## Pocket icon

`Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` is the project's three-session-row icon, created by redrawing its Pocket PWA geometry at 1024 pixels. Its creation is recorded in original revision `bb93854`; that private history is not part of this source snapshot. SHA-256: `7f10bde633c91ad2126d7153c40fcbd6e54d6b86527c6cf20b2042afb2b612d0`.

Project artwork is under the project MIT license. Third-party platform and source-code notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Naming a supported product does not imply endorsement or grant rights to its trademarks.
