# Third-party notices

The project-level [MIT license](LICENSE) applies to original project contributions. It does not override another author's terms or grant rights to vendor trademarks.

## CC Pocket

Upstream: https://github.com/K9i-0/ccpocket
Reference revision: `a505794`.

`Sources/TalkCache.swift` and `Sources/TalkPromptHistory.swift` acknowledge CC Pocket's timeline-cache and prompt-history design. Preserve these acknowledgements and [LICENSES/ccpocket-MIT.txt](LICENSES/ccpocket-MIT.txt): MIT, Copyright (c) 2026 K9i. The notice is retained conservatively for both design references and any adapted implementation; it is not a claim that every line was copied.

## Project artwork

- The twelve `AgentClaude`, `AgentCodex`, `AgentGrok` and `AgentUnknown` template PNGs are project-drawn geometric marks. Every pixel matches the project's drawing recipe. They are not supplied by or endorsed by the named vendors; source drawing functions are included in `scripts/generate_public_assets.py`.
- `AppClaude`, `AppCodex` and `AppHybrid` PNGs are independent generic terminal drawings created for this public snapshot. They replace the previous images, whose origin was not confirmed.
- The three `HarnessAvatar` PNGs are independent robot drawings created for this public snapshot. They are not the Hermes artwork.
- `skill.swordshield.symbolset` uses independently drawn shield and straight-sword paths. The Xcode custom-symbol document guides are retained for the asset format.
- `AppIcon.appiconset/AppIcon-1024.png` is the project's three-session-row Pocket icon, recorded in its original icon creation change. It is not a screenshot or vendor icon.

The project artwork is included under the project MIT license. See [ASSET_SOURCES.md](ASSET_SOURCES.md) for reproduction and provenance. Names identifying agent compatibility do not imply affiliation or a license to third-party marks.

## Platform dependencies and fixtures

SwiftUI, UIKit, XCTest, system symbols, Apple SDKs and Xcode are supplied separately by Apple under their own terms. This repository does not include an Apple signing identity, provisioning profile, App Store authorization or service account.

Captured user/work fixtures are not included. The Activity stub is synthetic empty data. Tests use explicit artificial endpoints and must not be pointed at a real session. Public availability of application code never authorizes publication of users' conversations.
