# Security policy

This is a source preview, not a reviewed App Store or TestFlight release. Pair only with a server you control, using HTTPS and the server's authenticated private-network entry point. Do not share accounts, OAuth material, server tokens or signing credentials.

The optional relay endpoint is empty by default. The hub uses the selected paired machine. Legacy JavaScript shard filenames do not configure or authorize connections to the author's machines.

DRY mode may still make real GET requests. Use a network-isolated URLSession stub and synthetic data for tests; never run normal-send checks against an existing user session. Source and asset checks do not replace a security review of a deployment.

## Reporting vulnerabilities

Use GitHub's **Security → Report a vulnerability** for [miyafcos/pocket-ios-oss](https://github.com/miyafcos/pocket-ios-oss/security/advisories/new). If private reporting is unavailable, ask the maintainer for a private route without including sensitive details in the public request.

Do not post conversations, private screenshots, server details, credentials or exploit details in public issues. Include only the minimum synthetic reproduction through the private route. Verification limits are recorded in [VALIDATION.md](VALIDATION.md).
