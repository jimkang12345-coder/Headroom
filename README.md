# Headroom

A free, open-source macOS dashboard for AI account capacity and API wallet balances. Headroom processes readings and history on your Mac and connects to the providers you choose. There is no Headroom account or hosted backend. Provider subscriptions and API usage retain their own costs.

This is an early development build. The current Mac source includes DeepSeek API balances, Codex subscription limits through the official local client, and Claude website or Claude Code feed connections. Unknown and stale readings remain visible as such. Native desktop widgets are planned, not yet implemented. The included iOS source is deferred while Mac work is prioritized.

## Build on Mac

Requires macOS 14 or later, Xcode with the macOS SDK, Python 3 and command-line developer tools. The shared package uses Swift 6. No third-party Swift package dependencies are required.

```sh
./script/build_and_run.sh --mac --build-only
./script/build_and_run.sh --mac --fixture
```

The script stages source into an owned temporary folder, generates the Xcode project there, runs core tests, builds an ad hoc signed Debug app and retains local build evidence. `--fixture` launches with a separate wallet folder, in-memory credentials and fresh fixture preferences. Enter Demo Mode in that instance for synthetic balances. It does not terminate an existing installed Headroom app.

To run a normal local instance, use `./script/build_and_run.sh --mac`. It can access your connected providers and real local data. Development builds are not notarized releases.

Additional offline checks:

```sh
swift test --package-path HeadroomCore
./script/subscription-regression/run.sh
./script/website-session-regression/run.sh
```

## Privacy and connections

- API keys use the system Keychain. Wallet/history files have owner-only POSIX permissions. This does not establish encryption or protection from software running as your own user.
- Fresh readings need provider requests. Official clients and embedded sign-in pages have their own network behavior; Headroom does not claim to control every request they make.
- Disconnecting Claude clears Headroom's dedicated website session. Cleanup failures are shown and block reconnect until retried.
- Embedded main-frame navigation is restricted to exact HTTPS origins. Other-origin and pop-up authentication flows are currently unsupported; the Claude Code feed is an alternative.
- JSON backups exclude API keys but contain account labels and balance history. Treat them as private backups.

Read [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md) and [ROADMAP.md](ROADMAP.md) for current boundaries and planned work. The first public app uses a neutral identity; it does not automatically migrate credentials from earlier private builds. Keep existing installations until a migration is deliberately reviewed.

## Contribute

Use synthetic fixtures for changes and screenshots. Include the checks you actually ran and keep credentials, live account data, personal paths, signing identities, build logs and private exports out of commits. See [CONTRIBUTING.md](CONTRIBUTING.md).

All Headroom features are intended to remain free. Source is released under the [MIT license](LICENSE).
