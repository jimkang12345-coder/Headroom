# Release readiness and known limitations

Headroom remains an early macOS developer preview. Sharing source, trying a local build and distributing a dependable signed app are different readiness decisions. Existing providers and features remain available; the safeguards below do not certify the app or its external clients.

## Safeguards in the source

- **Private backups:** Mac save and iOS share preparation use `PrivateSnapshotExporter`. New staging objects are restricted before private bytes are written. Publication uses the new file's metadata; failures remain errors. Existing-file replacement, inherited ACLs, write failure and invalid destinations have synthetic regressions.
- **Bounded numeric imports:** `CurrencyBalance` rejects decimal input above 320 UTF-8 bytes before trimming/scanning and normalizes in linear time. This shared boundary covers imported balances/targets and DeepSeek amounts. It preserves accepted exact values, signs and raw formatting, and accommodates the API-cost parser's bounded exponent expansion.
- **Reset safety:** unsupported/nonfinite reset dates become unavailable; countdown conversion cannot trap on an extreme numeric timestamp. A passed reset still awaits a provider update rather than inventing a refill.
- **Partial quota readings:** valid known windows remain visible. Unusable reported windows carry an incomplete state, aggregate summaries withhold a confident percentage and detailed views disclose missing limits. The website parser handles nested weekly “All models” headings without consuming another section's percentage. Codex's optional absent slots are not assumed to be applicable account limits.
- **Claude feed disconnect:** new connections have immutable generation-specific script/feed paths. Disconnect retires those paths before cleanup, preventing those writers from publishing after successful disconnect or into a new generation. Restoration/deletion failures remain retryable and block reconnection.
- **Deferred iOS edits:** editing an existing API connection retains its stored monthly target. Its Demo Mode copy no longer promises that an ordinary launch never touched private state. iOS remains deferred; these changes are not a phone-release claim.

## Known unresolved behavior

| Limitation | Practical consequence and current guidance |
| --- | --- |
| Already-running legacy Claude wrappers | Old code retains a shared output path and can recreate its old feed after disconnect. End/restart old Claude Code sessions, then disconnect/reconnect Headroom on upgrade. New generations do not read legacy output; existing legacy connections are not silently migrated. |
| Source/account attribution | Subscription readings do not carry a verified stable account identity. Multiple sessions using one current Claude feed still share that feed. Feed file modification time measures receipt, not source observation age. Check the actual provider account after switching accounts and treat values as advisory. |
| Multiple Headroom processes | Wallet/recovery files, preferences, Keychain service and website identity are shared; process-local guards do not coordinate whole-file writes between app instances. Concurrent instances can lose changes. Run one normal instance at a time until interprocess coordination is implemented. |
| Concurrent Claude settings edits | Connecting/disconnecting uses read-modify-write settings updates. Independently changed status-line commands are preserved when observed, but concurrent edits during an operation can still be overwritten. Avoid simultaneous settings writers. |
| Parser/provider compatibility | English website labels and local-client protocols can change. A provider can add limits this version does not recognize. Missing data is not evidence of unused capacity; inspect the provider's own usage view when a reading is incomplete or delayed. Other-origin and pop-up website authentication are unsupported. |
| Retention and exports | Disk pruning retains the latest observation even when old; a long-running session can retain additional in-memory history for export. There is no strict 30-day erasure guarantee. Backups remain private and user-selected cloud folders/OS backups are outside Headroom's synchronization controls. |
| Deferred iOS API presentation | iOS source still allows optional API connections without the Mac cost-report presentation. Do not promote it as feature-equivalent or release-ready. |

## Unverified release behavior

These are verification gaps, not assertions that each mechanism is broken:

- Real provider authentication, billing reconciliation, current Claude DOM/localization/SSO, live account switching and supported local-client versions.
- Full subprocess timeout/descendant cleanup, sustained multi-session use, and a complete crash/restart/soak matrix.
- Keychain access/backend/migration across release signing identities, upgrades and lock states. Random synthetic Keychain tests do not establish those properties.
- Real runtime network traffic of WebKit subresources and external clients. The Mac app is not App Sandbox enabled; the sandbox/helper design still needs review.
- Signed/notarized versioned download contents, Gatekeeper/quarantine behavior, clean-machine install/upgrade/uninstall/rollback, Intel and minimum-supported macOS runtime behavior, and authenticated update delivery. The current build script produces an ad hoc Debug app, not that release artifact.
- Repository history secrets and final packaged-binary/asset provenance. Current-tree review is narrower than those checks.

Before widening a beta, resolve the applicable known defects, run the synthetic checks below on the final source, then separately validate the supported accounts/client versions and real distribution artifact. No paid model request is needed merely to test the local parsers.

```sh
swift test --package-path HeadroomCore
./script/subscription-regression/run.sh
./script/website-session-regression/run.sh
./script/build_and_run.sh --mac --build-only
```

Record the exact revision and results. A passing synthetic suite or build does not prove live-provider accuracy, installation readiness or universal safety. See [PRIVACY.md](../PRIVACY.md) for the data boundary and [SECURITY.md](../SECURITY.md) for private reporting.
