# Headroom

A free, open-source macOS app focused on tracking **Codex and Claude Code subscription limits**. Headroom processes readings and history on your Mac and connects to the providers you choose. There is no Headroom account or hosted backend. Provider subscriptions and API usage retain their own costs.

This is an early development build. Its home screen and menu bar prioritize Codex and Claude Code quota windows, remaining capacity, resets and reading freshness. Codex uses the official local client; Claude Code uses a local status-line feed, with a Claude website connection available as an alternative. Optional API trackers can be added separately: OpenAI and Anthropic organization-reported API spend with local monthly targets, plus DeepSeek wallet balances. Unknown and stale readings remain visible as such. Native desktop widgets are planned, not yet implemented. The included iOS source is deferred while Mac work is prioritized.

## Build on Mac

Requires macOS 14 or later, Xcode with the macOS SDK, Python 3 and command-line developer tools. The shared package uses Swift 6. No third-party Swift package dependencies are required. The Claude Code feed uses jq, which macOS 15 and later include; on macOS 14, install it with `brew install jq`.

```sh
./script/build_and_run.sh --mac --build-only
./script/build_and_run.sh --mac --fixture
```

The script stages source into an owned temporary folder, generates the Xcode project there, runs core tests, builds an ad hoc signed Debug app and retains local build evidence. `--fixture` launches with a separate wallet folder, in-memory credentials and fresh fixture preferences. The fixture instance displays labeled synthetic Codex/Claude Code limits. Enter Demo Mode for synthetic wallet examples too. All supported API fixture transports stay offline; the setup view lists the matching synthetic key markers. It does not terminate an existing installed Headroom app.

To run a normal local instance, use `./script/build_and_run.sh --mac`. It can access your connected providers and real local data. Development builds are not notarized releases.

Additional offline checks:

```sh
swift test --package-path HeadroomCore
./script/subscription-regression/run.sh
./script/website-session-regression/run.sh
```

## Optional API trackers

Codex and Claude Code subscriptions work without API reporting keys. Add API trackers only when you want separate budget or balance information:

| Provider | Reading | Credential |
| --- | --- | --- |
| OpenAI API | Organization-reported month-to-date USD spend | OpenAI organization Admin API key |
| Anthropic API | Organization-reported month-to-date USD spend | Anthropic organization Admin API key |
| DeepSeek | Provider wallet balances by currency | DeepSeek API key |

Organization Admin keys have elevated privileges; Headroom only calls read-only reporting endpoints. Regular project/workspace model keys are not sufficient for these reporting connections. API reports can lag and change; Anthropic Priority Tier costs are excluded. A local monthly target is a comparison reference, not available credit or a provider-enforced spending cap. See [API tracker details](docs/api-trackers.md).

## Privacy and connections

- API keys use the system Keychain. Wallet/history files have owner-only POSIX permissions. This does not establish encryption or protection from software running as your own user.
- Fresh readings need provider requests. Official clients and embedded sign-in pages have their own network behavior; Headroom does not claim to control every request they make.
- Disconnecting Claude clears Headroom's dedicated website session. Cleanup failures are shown and block reconnect until retried.
- Embedded main-frame navigation is restricted to exact HTTPS origins. Other-origin and pop-up authentication flows are currently unsupported; the Claude Code feed is an alternative.
- JSON backups exclude API keys but contain account labels, balance history, API cost reports and local targets. Treat them as private backups.

Read [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md) and [ROADMAP.md](ROADMAP.md) for current boundaries and planned work. The first public app uses a neutral identity; it does not automatically migrate credentials from earlier private builds. Keep existing installations until a migration is deliberately reviewed.

## Contribute

Use synthetic fixtures for changes and screenshots. Include the checks you actually ran and keep credentials, live account data, personal paths, signing identities, build logs and private exports out of commits. See [CONTRIBUTING.md](CONTRIBUTING.md).

All Headroom features are intended to remain free. Source is released under the [MIT license](LICENSE).
