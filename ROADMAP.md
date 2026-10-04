# Mac roadmap

Headroom primarily tracks **Codex and Claude Code subscription limits**. Quota windows, remaining capacity, resets, source health and freshness drive the default home and menu bar. API spend/balance trackers are optional additions, never a requirement for using subscription tracking.

## Implemented

- Limits-first Mac home/sidebar and menu summaries for Codex and Claude Code.
- Claude Code local feed as the primary connection; Claude website as an explicit alternative.
- Optional OpenAI/Anthropic organization cost reports and local monthly targets; DeepSeek wallet balances.
- Reviewed MIT public source, private local storage modes and Claude website-session cleanup/retry.
- Offline synthetic limits and API fixtures, private backup guidance and automated Mac checks.

## Next

1. Improve Codex/Claude Code account-change detection, multi-session behavior and connection diagnostics; verify live provider/client behavior without inventing missing limits.
2. Add a credential-free local summary cache, then configurable native Mac widgets prioritizing Codex and Claude Code quota windows, resets and observation age.
3. Add local low-headroom alerts, quiet hours and bounded optional quota history. Never fabricate a refill when a reset timer expires.
4. Keep API extras easy to add; improve reporting coverage and credential guidance independently of subscription tracking. Local targets remain comparison values rather than hard caps.
5. Review an App Sandbox compatible CLI/helper architecture and Keychain migration, then signed/notarized distribution and exact release contents.

iPhone development, device pairing and cloud synchronization are deferred. Native widgets are planned. The online maintainer journal holds curated product records; the app uploads no user data to it.
