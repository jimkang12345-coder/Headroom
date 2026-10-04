# Privacy contract

Headroom's goal is local private processing, explicit provider connections and no Headroom backend, advertising or automatic diagnostic uploads. This source has no Headroom telemetry endpoint. This document describes the implementation boundary, not a security certification.

## Data on this Mac

API credentials are stored in the system Keychain and kept out of wallet JSON. Wallet records, recovery records and backups contain private account labels and observations. The app restricts its storage directory to mode `0700` and its data files to `0600`, repairs older modes and rejects substituted symlinks. POSIX modes do not remove existing ACL grants, encrypt the files or defend against a compromised user account or administrator.

Appearance and connection flags use local preferences. A Debug fixture launch uses a fresh separate preference suite, temporary wallet folder and in-memory credentials. Normal Demo Mode shows synthetic data, but a normal app may have loaded private state before demo was selected. Use the explicit fixture launch for evidence capture.

## Data leaving this Mac

Connected provider APIs receive authenticated requests and ordinary connection metadata. The Codex integration invokes the local official client. The optional Claude Code integration installs a local status-line feed and consumes reported subscription metrics. Those external clients have their own privacy policies and behavior.

The optional Claude website connection is a separate persistent WebKit session. The provider and its page resources can make requests. Exact HTTPS main-frame navigation restrictions and pop-up rejection do not confine all subresource traffic. Disconnect destroys the view and removes the dedicated website data store; a failure remains visible and must be retried before reconnection.

No cloud history synchronization or developer diagnostics upload is implemented. A user can deliberately save or share an export; OS backups and user-selected cloud folders are outside the app's synchronization controls. Exports contain private observations even though they exclude API keys.

## Work still required

The Mac target is not App Sandbox enabled. Review sandbox/helper compatibility with local CLI integrations, Keychain backend/migration semantics, ACLs, signed update delivery and exact runtime network behavior before a distribution release. No claim of universal safety, device-only Keychain behavior on every Mac backend, or complete third-party network confinement is made.

Desktop widgets will consume a minimal local cache without credentials or browser sessions. Widget extensions, App Group configuration, redaction and cache deletion are still planned.
