# Validation

Checked on 2026-10-25 against this public source preview. This file reports completed checks, not a general security or compatibility guarantee.

## Completed

- `node scripts/test_read_only.mjs`: **86 checks passed**, with networking disabled.
- `xcodegen generate --spec project.yml`: project generation succeeded.
- Xcode 26.2 (17C52), iOS simulator SDK, Debug `build-for-testing`, generic iOS Simulator destination: **TEST BUILD SUCCEEDED** for the app and `PocketIOSTests`, including the replacement images and symbol. Code signing was disabled. The input source snapshot remained unchanged during the build.
- All nineteen PNG assets decoded successfully. Twelve agent-mark images matched their drawing functions pixel-for-pixel; six previously unconfirmed PNGs and the custom symbol were replaced with independent project artwork. The remaining Pocket app icon was matched to the project's original artwork record.
- Public source privacy checks and Gitleaks found no secret values. Stable bundle/logger identifiers, the author's copyright notice and legacy shard filenames remain intentionally; they are not private server connection settings.

## Existing build warnings

All distinct warnings from the simulator build are listed here; duplicate architecture compilations are not repeated.

- `Sources/PocketAlerts.swift:72`: unnecessary `nonisolated(unsafe)` for a Sendable constant.
- `Sources/VideoAttachment.swift:127`: `AVMutableVideoCompositionInstruction` deprecated in iOS 26.
- `Sources/VideoAttachment.swift:129`: `AVMutableVideoCompositionLayerInstruction` deprecated in iOS 26.
- `Sources/VideoAttachment.swift:132`: `AVMutableVideoComposition` deprecated in iOS 26.
- `Sources/PocketApp.swift:49`: actor-isolated `iconOnly` referenced from a nonisolated context.
- `Sources/PocketApp.swift:52`: actor-isolated `iconOnly` referenced from a nonisolated context.
- `Sources/PocketStub.swift:386`: non-Sendable function converted to a Sendable block.
- `Sources/ReaderChrome.swift:136`: actor-isolated `body` referenced from a nonisolated context.
- AppIntents metadata extraction skipped because no AppIntents framework dependency is present.

These warnings were not silently fixed as part of source publication. In particular, compilation does not establish the absence of concurrency defects.

## Not performed

XCTest execution, simulator app installation/launch, real-device operation, live pairing, sending to a real terminal, account switching, signing, IPA distribution, App Store/TestFlight submission and a full endpoint security audit were not performed. The test bundle was compiled, not executed. A DRY flag is not a network sandbox.

No new dependency packages were installed for these checks. The app and test build used an isolated work copy, not an existing installed app or production project.
