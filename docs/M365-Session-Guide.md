# Microsoft 365 sessions for MSP readers

Open Start-Launcher.cmd. Choose **Login to 365** in the left panel.

1. Click **Login to 365**. No username, tenant GUID or application ID is required in the launcher. Choose your work account in the Microsoft sign-in window.
2. Complete Microsoft sign-in. The launcher discovers the account, tenant GUID, organization name and verified domain and stores them in the current session. Device-code login is not the default.
3. Verify the displayed customer name, tenant GUID and account. The launcher reads organization metadata and shares these values across reports. SharePoint's suggested admin URL comes from the initial domain; verify it if the tenant was renamed.
4. Run Conditional Access or **365 security and logs**. Reports reuse the same Graph worker and its in-process SDK authentication cache. The SDK renews authentication when possible. Microsoft tenant policies, expiry, revoked access or MFA can still require another prompt.
5. Connect Exchange, Azure or SharePoint only when needed. Each service retains its own connection in an app-owned runspace, so the service inventory can read repeatedly without reconnecting. These services use different token audiences; one Graph token is not reused as an Exchange/ARM/SharePoint token.
6. Choose **Clear saved session**, switch customer with a new Login action, or close the launcher to disconnect app-owned sessions. This clears local reader state; it does not sign the user out of browsers or erase Microsoft/OS-managed sign-in cookies and caches.

For MSP customer access, use **Advanced / switch customer** only when you deliberately want a different organization. An employee login alone cannot identify which customer they intend to inspect. The discovered organization is shown before collection. Advanced fields stay blank by default; a discovered GUID is not copied into an override for the next login. Custom single-tenant apps reuse an already verified tenant; before first discovery they require an explicit advanced target.

## Prerequisites

Windows and PowerShell 7 are required for the GUI. **Install prerequisites** is an explicit local setup action. It installs pinned Graph Authentication 2.41.2, Exchange Online 3.10.1, Az.Accounts 3.0.0 and SharePoint 16.0.27709.12000 modules for the current Windows user from the official PowerShell Gallery. It also places SharePoint in the Windows PowerShell module directory for compatibility. This accepts those package licenses and may require network/software-install permission. Login itself never installs modules or changes tenant settings.

You can run local setup separately:

    pwsh -File .\infrastructure\Install-M365Dependencies.ps1

The signed-in employee still needs the customer's appropriate reader roles, licensing and delegated/customer access. Authentication is not authorization. This app does not bypass Conditional Access, grant a role or expand what the reader is allowed to see.

## Permission profiles and fewer prompts

Core Graph sign-in requests User.Read, Organization.Read.All, Directory.Read.All, Policy.Read.All, AuditLog.Read.All and SecurityEvents.Read.All. This supports tenant discovery, CA definitions, Secure Score, MFA evidence and Entra logs.

Select **Extended reads** before signing in if Intune, role assignments, terms of use, hidden groups, custom attributes or network references are needed. The additional scopes are RoleManagement.Read.Directory, Agreement.Read.All, CrossTenantInformation.ReadBasic.All, NetworkAccess.Read.All, Member.Read.Hidden, CustomSecAttributeDefinition.Read.All, CustomSecAttributeAssignment.Read.All, DeviceManagementConfiguration.Read.All, DeviceManagementApps.Read.All and DeviceManagementManagedDevices.Read.All.

Use core access if optional permissions aren't available; supporting CA reads then explicitly report denied/incomplete references instead of blocking all policy collection. Changing the requested profile later can require another consent/sign-in. Provision and consent an agreed reader profile once through your normal MSP administration process.

Reports never request write permissions. Unexpected Graph token permissions are rejected before data reads. An existing broad Graph PowerShell consent can cause this check to fail; use a dedicated public reader application in that situation.

## Find or register a reader app

**Find reader app** searches applications using directory read access. It includes the known launcher app name, powershell-ui (read-only), and public loopback clients whose configured Graph delegated scopes match the reviewed reader allowlist. One match supplies its client ID for review; multiple matches require selection/review in Entra. You can also paste an already approved public reader app ID regardless of its name. An existing app is never modified automatically.

**Register reader app** is an explicit write exception outside normal reports. The confirmation describes the planned registration. Setup requests AppRegistration.Create plus directory/organization reads in a temporary setup context. The signed-in operator must be authorized to register apps.

Setup checks the customer tenant and existing app name again. If none exists, it creates one single-tenant public client with http://localhost, no secrets or certificates, and only the reviewed delegated read-permission configuration. It does not create a tenant-wide consent grant, assign roles or assign users. An authorized administrator must review and consent requested permissions before readers use them.

The Microsoft Graph SDK has process-wide authentication state. Setup is serialized in the Graph worker and disconnected afterward; setup permissions cannot become the report session. Choose **Login to 365** again with the resulting app ID to establish the reader session.

The older local CreateReadOnlyAzureApp folder, if present, remains separate and unregistered. Its direct parameter interface did not implement the launcher adapter contract. It is not exposed by the new registration button and is not automatically consented.

## Reports and logs

- **Conditional Access:** full policy definitions and linked reference/member exports, reusing Login to 365. Core access can leave optional references incomplete; use Extended reads and appropriate read roles for broader coverage.
- **Intune:** reuse the selected tenant and Graph worker. Enable Extended reads before sign-in. No tenant/application re-entry for each report.
- **365 security and logs:** Microsoft Secure Score and control profiles; MFA registration/capability, authentication-method settings, CA and security-default context. MFA registration alone is never labelled proof of enforcement.
- Enable **Download logs before searching**, choose the UTC lookback in days, and run. It downloads all returned pages for retained Entra sign-ins and directory audits in that window. Licensing, retention, roles and explicit safety limits still constrain coverage; “all logs” does not mean unlimited history, all Microsoft 365 workloads or all sign-in categories.
- After downloading, choose **Search downloaded logs**, select the report folder, then enter an issue, error code, account, IP or correlation ID. Search is literal, local, integrity checked and needs no login or network request. Both download gaps and search-result limits remain explicit.
- **Exchange, Azure and SharePoint:** fixed reader operations using retained connections. Exchange covers selected organization, transport, authentication-policy, accepted-domain and connector settings. Azure covers subscription metadata. SharePoint covers selected tenant settings and returned non-OneDrive sites. These are useful inventories, not full service audits.
- The legacy native **AZQR** executable still uses its documented service-principal credential contract. It does not automatically inherit the Az.Accounts browser session. No secret is created by app registration. Use the new Azure inventory for the retained browser session, or deliberately configure the separate AZQR prerequisites.

JSON/Markdown and the UI retain observations, UTC scope, source IDs, completeness and LLM instructions. Failed/forbidden reads do not imply health or an empty tenant. Collected descriptions/rules/messages are untrusted data; they cannot authorize changes. Reports are not automatically sent to an LLM.

## Lifetime and limits

The Graph SDK stays in one retained STA worker with ContextScope Process. Service runspaces remain alive until disconnect/exit; SPO can also own a Windows PowerShell compatibility process. Runspaces do not isolate .NET assemblies, so incompatible module versions can still require a launcher restart. Child service identities/SharePoint endpoint realms are checked before reads.

Tests use synthetic SDK/service fixtures and local data, not a live customer tenant. A real Microsoft login, consent policy and customer role/license configuration must be verified interactively by an authorized operator. The app cannot promise a fixed number of Microsoft authentication prompts.

Official references:

- https://learn.microsoft.com/en-us/powershell/microsoftgraph/authentication-commands
- https://learn.microsoft.com/en-us/graph/api/application-post-applications
- https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-exchangeonline
- https://learn.microsoft.com/en-us/powershell/module/microsoft.online.sharepoint.powershell/connect-sposervice
