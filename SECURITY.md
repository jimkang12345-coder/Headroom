# Security

Headroom is an early local macOS app. A source build is not a notarized, audited distribution release. Review [PRIVACY.md](PRIVACY.md) for its actual trust boundary.

For vulnerabilities, use this repository's **Security → Advisories → Report a vulnerability** private reporting route. Do not put credentials, session cookies, live balances, private exports or raw local logs in public issues. Include a minimal synthetic reproduction, affected source revision and the observed behavior.

If a credential is accidentally exposed, revoke it with its provider. Removing a file or Git commit does not revoke access.

Contributors should use mocked transports, temporary storage, random dedicated test Keychain/website-store identities and fixture screenshots. Tests must never delete a production website session or make paid model requests merely to refresh a gauge.

Current safeguards and remaining defects/verification gaps are recorded in [release readiness](docs/release-readiness.md). In particular, run one normal app instance, reconnect legacy Claude Code feeds after restarting old sessions, and do not treat a successful build, synthetic regression test or notarization as a safety certification.
