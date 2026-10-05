# Privacy contract

Headroom's goal is local private processing, explicit provider connections and no Headroom backend, advertising or automatic diagnostic uploads. This source has no Headroom telemetry endpoint. This document describes the implementation boundary, not a security certification.

## Data on this Mac

API credentials are stored in the system Keychain and kept out of wallet JSON. Wallet records, API cost reports, local budget targets, recovery records and backups contain private account labels and observations. The app restricts its storage directory to mode `0700` and its data files to `0600`, repairs older modes and rejects substituted symlinks. Those internal-storage modes do not remove existing ACL grants, encrypt files or defend against a compromised user account or administrator.

Exports use a separate private staging directory and a new `0600` file before writing private bytes. The exporter removes inherited ACLs from its new staging objects, verifies protection and atomically publishes the new file without inheriting an old destination's permissions. It never changes the selected folder's ACL. Permission, write or publication failures are reported rather than described as successful exports; an existing backup is preserved when publication fails. Symbolic-link destinations and folders are rejected. Filesystems that cannot enforce these protections are unsupported export destinations. A local folder with POSIX permissions is the recommended destination; this does not control later copies, sharing or cloud synchronization.

Imported decimal fields are limited to 320 UTF-8 bytes, including signs and whitespace, in addition to the overall 5 MiB backup limit. Excessive padding is rejected rather than truncated; accepted amounts retain their original formatting and exact value. Disk history pruning retains each wallet's latest observation, even when older than the retention window. A long-running session can also export older in-memory history, so no strict 30-day erasure guarantee is made.

Appearance and connection flags use local preferences. A Debug fixture launch uses a fresh separate preference suite, temporary wallet folder and in-memory credentials. Normal Demo Mode shows synthetic data, but a normal app may have loaded private state before demo was selected. Use the explicit fixture launch for evidence capture.

## Data leaving this Mac

Connected provider APIs receive authenticated requests and ordinary connection metadata. Optional OpenAI and Anthropic reporting adapters send organization Admin credentials only to their fixed HTTPS reporting origins, reject redirects and bound responses/pagination. They call read-only cost endpoints; a local monthly target does not alter provider billing settings. The Codex integration invokes the local official client. The optional Claude Code integration installs a local status-line feed and consumes reported subscription metrics. Those external clients have their own privacy policies and behavior.

New Claude Code feed connections use unique generation directories. Disconnect retires their paths before restoring settings and deleting data; failures remain visible and block reconnect until cleanup succeeds. A pre-upgrade wrapper that is already running cannot be revoked retroactively and can recreate its old shared feed file. End or restart those Claude Code sessions and disconnect/reconnect Headroom when upgrading. The new generation never reads that legacy file. Existing legacy connections keep their old behavior until reconnected. No provider-side sign-in or API key is revoked by Headroom's local disconnect.

Feed receipt time is not a provider observation timestamp. Multiple Claude Code sessions bound to the same current feed still share it, and Codex/Claude readings are not bound to a verified stable account identity. Account changes, client-version changes and concurrent settings edits require care; see [known limitations](docs/release-readiness.md).

The optional Claude website connection is a separate persistent WebKit session. The provider and its page resources can make requests. Exact HTTPS main-frame navigation restrictions and pop-up rejection do not confine all subresource traffic. Disconnect destroys the view and removes the dedicated website data store; a failure remains visible and must be retried before reconnection.

No cloud history synchronization or developer diagnostics upload is implemented. A user can deliberately save or share an export; OS backups and user-selected cloud folders are outside the app's synchronization controls. Exports contain private observations even though they exclude API keys.

## Work still required

The Mac target is not App Sandbox enabled. Review sandbox/helper compatibility with local CLI integrations, Keychain backend/migration semantics, ACLs, signed update delivery and exact runtime network behavior before a distribution release. No claim of universal safety, device-only Keychain behavior on every Mac backend, or complete third-party network confinement is made.

Desktop widgets will consume a minimal local cache without credentials or browser sessions. Widget extensions, App Group configuration, redaction and cache deletion are still planned.
