# Optional API trackers

Headroom's main features are Codex and Claude Code subscription limits. These API additions report separate API costs and do not establish subscription headroom.

## OpenAI

The adapter calls `GET https://api.openai.com/v1/organization/costs`, using an organization Admin API key and the current UTC month start through the query snapshot. It reads daily buckets and follows bounded pagination, totaling reported USD costs with exact decimal arithmetic. A regular model/project key cannot access this report.

## Anthropic

The adapter calls `GET https://api.anthropic.com/v1/organizations/cost_report`, using an organization Admin API key with `anthropic-version: 2023-06-01`. It queries the current UTC month, reads daily USD cost buckets and converts provider amounts in cents to dollars exactly. Workspace model keys and individual Claude subscriptions are insufficient. Priority Tier costs are excluded by the provider's report.

## Meaning and privacy

The displayed value is provider-reported API spend, not remaining prepaid credit, a real-time bill or Codex/Claude Code quota. Daily reports can lag and be revised. If pagination fails, a response is malformed or the safe bounds are exceeded, no partial total replaces the prior reading. Existing readings keep their timestamp and error state.

A positive optional USD monthly target is stored locally. The app compares the displayed report period with that reference; it does not change a provider limit or stop paid requests. Keys use Keychain and are excluded from JSON backups; cost records, labels and targets are private backup contents.

These reporting keys have elevated organization privileges. Headroom only uses read-only fixed-origin requests and performs no organization administration or paid inference. Its clients reject redirects, unexpected response origins, oversized bodies, invalid currencies and inconsistent bucket pagination. First-release bounds are four pages, 256 KiB per page, 64 daily buckets and 4096 cost entries; larger or inconsistent reports show unavailable rather than a fabricated partial amount.

## Development verification

Use mocked clients or `--fixture`. The fixture setup view documents synthetic key markers and all API transports remain offline. Live organization authentication/billing reconciliation requires separate verification; successful synthetic tests do not prove live account access.

## Official references

- [OpenAI organization usage and costs](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage)
- [OpenAI Admin API keys](https://platform.openai.com/docs/api-reference/admin-api-keys)
- [Anthropic usage and cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)
- [Anthropic cost report reference](https://platform.claude.com/docs/en/api/beta/organization/cost_report/retrieve)
