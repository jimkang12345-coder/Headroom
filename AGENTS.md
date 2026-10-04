# Headroom contributor guidance

Read README.md, PRIVACY.md and SECURITY.md before changing data acquisition, storage, authentication or exports. Preserve unrelated work and coordinate one writer per overlapping file. The repository is authoritative for source and checks. Codex and Claude Code subscription limits are the primary product; API cost/balance trackers are optional additions. Preserve unknown/stale quota states and keep API spend separate from subscription capacity.

Use mocked providers, owned temporary storage and random test credential/session identities. Do not use real accounts for tests or screenshots. Build through script/build_and_run.sh; use --fixture for Mac evidence capture. Do not replace an existing installed app to gather evidence.

Before handoff, summarize the user-facing result, changed files, actual checks and remaining limits. Distinguish proposals, implementation and runtime verification. Do not claim App Sandbox, network confinement, widget support or release signing until verified.

If docs/development-journal.local.md exists, follow that private maintainer workflow during authorized sessions. It is ignored local routing and must never be committed or uploaded. Missing cloud tools mean a reviewed local pending update, not a fabricated successful save. No background logging is implied.
