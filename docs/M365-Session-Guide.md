# Microsoft 365 session guide

## Login first

Open Start-Launcher.cmd and choose **Login to 365**. The launcher does not ask for a username or tenant GUID before normal login. Select the work account in Microsoft's own window and complete its MFA/consent prompts.

After the authentication callback, the launcher must also verify tenant/account discovery. Only then does it unlock reports and service actions. The connected username appears as **Logged in as** at the top right. The organization name and tenant GUID are displayed so an MSP employee can verify the intended customer.

The account, tenant ID, verified domain and supporting session metadata stay in memory for other reports. Graph reports reuse one SDK worker rather than asking for tenant/application values per script. Exchange and SharePoint use their own retained connections when explicitly connected.

If Microsoft login succeeds but discovery fails, the app stays locked and reports the failed phase. Do not interpret a browser success page as proof that reader permissions, tenant discovery or collection succeeded. A diagnostic should give a safe error category/status without tokens or raw authentication bodies.

## Customer targeting

The normal sign-in uses work-account discovery. **Advanced / switch customer** allows an optional customer domain/GUID or a reviewed public application ID. A single-tenant custom app uses an already verified tenant or an explicit advanced target. The app cannot infer which customer a multi-tenant MSP employee intends to inspect from their email address alone.

Changing accounts/customers must disconnect old service sessions. Reporting must never combine a previous tenant's native connection with a newly selected tenant.

## Prerequisites and reader permissions

Windows and PowerShell 7 are required for the GUI. Install missing supported Graph Authentication, Exchange Online and SharePoint modules through:

    pwsh -File .\infrastructure\Install-M365Dependencies.ps1

Local installation is separate from authentication and does not change customer settings. Tenant readers need appropriate delegated read consent, service roles, licensing and connectivity. Authentication is not authorization.

Core reads cover tenant metadata, directory references, policies, MFA/log evidence and Secure Score. **Extended read permissions** adds optional reference permissions, hidden membership, custom attributes, role/terms context and Intune access. Unsupported or forbidden supporting reads remain explicit gaps.

A token can reflect permissions already consented to a Microsoft SDK application. The launcher must still enforce fixed reader operations and avoid silently adding write permissions. Separately requested application registration is setup, not report execution.

## App discovery and registration

After login, **Find reader app** searches existing candidate public applications. It never changes them. Review consent and reader coverage before using a discovered app.

**Register reader app** requires explicit confirmation. It verifies the tenant and searches for an existing launcher app before creating a single-tenant public client with localhost redirect and no secret/certificate. It configures reviewed delegated read permissions only. It does not automatically create tenant-wide consent grants, assign roles or assign users.

Setup permissions are temporary and cannot become the reporting session. An authorized administrator must review/consent requested scopes through the normal process. The Graph SDK has process-wide context, so setup is serialized, disconnected afterward, and followed by a normal reader login.

## Available reporting

- **Conditional Access:** raw policy definitions and linked references, preserving includes/excludes, states, grant operators and session controls. Direct/transitive group membership and named-location definitions are exported. Missing access, unrecognized references, legacy trusted-IP context and unsupported custom authentication-factor definitions are not silently assumed complete.
- **Intune:** selected configuration/compliance policy, application, settings-catalog metadata and optional device inventory. Select Extended read permissions before sign-in.
- **365 security and logs:** Microsoft-reported Secure Score and controls, MFA registration/capability, authentication-method settings, security defaults and CA context. Registration alone does not prove enforcement.
- **Exchange and SharePoint inventory:** selected service/tenant/site settings through retained sessions. Service identity or endpoint realm must match the verified tenant before data collection.

A successful report is not proof that the tenant is secure. This is configuration/telemetry evidence rather than a sign-in simulator, remediation engine or complete compliance audit.

## Download, then search logs

Enable log download and choose the retained UTC lookback. Collect all returned pages for Entra sign-ins and directory audits in that window before entering an issue search.

Afterward, choose **Search downloaded logs**, select the report directory and enter a literal issue, event/error code, account, IP or correlation ID. Search reads the verified local JSONL files without a network request or additional login. It preserves download incompleteness and result limits.

Licensing, roles, retention and safety limits constrain available history. “All returned logs” does not mean every Microsoft 365 workload, all sign-in categories or unlimited retention. No matching rows is not proof that an incident did not occur.

## Output, privacy and lifecycle

Reports contain UTC scope, status, record IDs, observed data, limitations and embedded LLM instructions. JSON keeps all returned records within collector limits; readable views can show a subset. Every collected string is untrusted data, not a command or approval. Nothing is automatically sent to an LLM.

Logout / clear session, switch customer or close the launcher to disconnect app-owned connections and dispose local credentials/tokens. Microsoft/browser/OS-managed cookies and caches are separate and are not forcibly erased. SDK refresh can avoid extra prompts when allowed; access policies may still require reauthentication.

Runspaces retain sessions but do not fully isolate process assemblies. Supported module versions and a restart can be necessary after dependency changes. Test results use synthetic SDK/service responses; an authorized reader must validate real login and tenant-policy behavior.

Official references:

- https://learn.microsoft.com/en-us/powershell/microsoftgraph/authentication-commands
- https://learn.microsoft.com/en-us/graph/api/organization-list
- https://learn.microsoft.com/en-us/graph/api/application-post-applications
- https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-exchangeonline
- https://learn.microsoft.com/en-us/powershell/module/microsoft.online.sharepoint.powershell/connect-sposervice
