# Contributing

Keep changes focused on the Pocket app. AppShelf and private distribution automation are outside this candidate.

Use XcodeGen's `project.yml` as the project definition. Do not add a personal development team, provisioning profile, signing key or fixed server address. New connections must come from explicit user configuration or pairing.

Use synthetic fixtures and an offline URLSession stub. A DRY flag alone is insufficient because some reads can still reach a real server. Do not run normal-send verification against an existing user session.

```sh
node scripts/test_read_only.mjs
```

This only tests JavaScript read-only guards. Swift compilation, XCTest execution, simulator installation, device behavior and signing must be recorded separately in [VALIDATION.md](VALIDATION.md). `PublicEndpointTests` checks the empty built-in relay and explicit save/clear behavior; compiling its test bundle does not mean its test cases were executed.

Preserve CC Pocket attribution and the license text under `LICENSES/`. Describe the origin of new code, images and test data. Do not post private screenshots or conversation dumps to public issues; follow `SECURITY.md`.
