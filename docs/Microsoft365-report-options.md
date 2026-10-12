# Microsoft 365 and Exchange reporting recommendation

Research checked 12 October 2026. These are recommendations, not installed launcher adapters. No tenant scan or new permissions have been applied.

## Recommended combination

Use **Monkey365** for configuration evidence and security findings, alongside **Microsoft Graph Secure Score** for Microsoft's actual score.

[Monkey365](https://github.com/silverhack/monkey365) assesses Exchange Online, Entra ID and other Microsoft 365 workloads. It exports HTML, JSON and CSV and evaluates configuration against security rules, including a Microsoft 365 CIS benchmark. Its self-contained PowerShell module avoids several separate Microsoft SDK installations. The project describes assessment operations as read-only.

For this launcher, start with Exchange Online and Entra ID. Review the pinned collectors and authentication lifecycle before enabling them. Microsoft's score and a tool's benchmark findings should appear separately in the UI.

## Actual Secure Score

Collect these fixed read endpoints:

- GET https://graph.microsoft.com/v1.0/security/secureScores
- GET https://graph.microsoft.com/v1.0/security/secureScoreControlProfiles

The first supplies dated score snapshots, current and maximum scores, and individual control scores. The second provides control titles, service, maximum points and remediation information. Both document **SecurityEvents.Read.All** as the least privileged delegated or application permission. Do not request SecurityEvents.ReadWrite.All. See Microsoft's [score API](https://learn.microsoft.com/en-us/graph/api/security-list-securescores?view=graph-rest-1.0) and [control profile API](https://learn.microsoft.com/en-us/graph/api/security-list-securescorecontrolprofiles?view=graph-rest-1.0).

The corresponding Graph PowerShell commands are Get-MgSecuritySecureScore and Get-MgSecuritySecureScoreControlProfile. A future launcher collector should use direct GET requests with in-memory authentication, follow validated pagination, and preserve observation dates. Do not assume the first returned snapshot is the newest; compare dates.

## Access and read-only constraints

Monkey365's [permission guide](https://silverhack.github.io/monkey365/getting_started/permissions/) specifies Global Reader for interactive Microsoft 365 collection. Its app-only Exchange guidance includes Exchange.ManageAsApp plus Global Reader. That permission's name alone does not restrict operations to reads; the assigned role and reviewed commands matter.

The same guide requires SharePoint Administrator for interactive SharePoint collection and Sites.FullControl.All for app-only collection. Those are write-capable permissions. Therefore, do not automatically grant access to every workload under a strict read-only authorization requirement. Omit workloads that cannot meet that requirement with a validated permission arrangement, and clearly record missing coverage.

Use an existing identity and registration provisioned through normal administration. Do not expose automatic application-registration helpers or remediation operations from the launcher. Prefer interactive MFA to storing a Microsoft 365 user password. Authentication methods vary by workload; consult the [support matrix](https://silverhack.github.io/monkey365/authentication/supported_auth_methods_byapp/). A username and password or one Azure application secret does not provide universal Microsoft 365 access.

## Proposed report content

- Scope, tenant identifier, observation time, enabled workloads and per-collector completion status.
- Actual Secure Score snapshots and control profiles, kept distinct from benchmark findings.
- Exchange and identity configuration evidence from reviewed collectors, with stable record IDs.
- Readable findings and evidence in the UI, complete JSON plus Markdown files, and the launcher's LLM instructions.
- Explicit unsupported, inaccessible and incomplete collections. Missing evidence must not count as a passing check.

The LLM should cite source record IDs and dates, separate observed settings from inferred risks, and suggest read-only verification for a human. Remediation text from Microsoft or a benchmark is evidence for discussion; it must never be executed automatically.

## Other options

| Tool | When it fits |
|---|---|
| [CISA ScubaGear](https://github.com/cisagov/ScubaGear) | Assessment against CISA's Microsoft 365 SCuBA baselines, including Exchange. Useful when those baseline results are the primary goal. |
| [Microsoft365DSC reporting](https://microsoft365dsc.com/user-guide/get-started/generating-reports/) | Reports from exported tenant configurations, including Markdown and JSON. An export-only integration would need careful separation from configuration deployment features. |

No tool establishes that every setting visible in every Microsoft 365 admin portal has been collected. Coverage depends on APIs, licenses, workload selection and access. Display the collected scope explicitly.
