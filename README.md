# Microsoft 365 reader utility

Windows PowerShell 7 launcher for MSP employees to sign in once, verify the connected organization, and reuse Microsoft 365 reader sessions. Start with **Login to 365**. No launcher-side username or tenant GUID is required for normal sign-in.

## Start

Double-click Start-Launcher.cmd, or run:

    pwsh -STA -File .\Start-PowerShellUI.ps1

The initial screen says **Please login to 365**. Reporting and service actions remain disabled until Microsoft sign-in and tenant discovery complete. Microsoft itself asks for the account, MFA or consent when necessary.

After authentication, the launcher reads the tenant GUID, organization details and account identity and stores them in session memory. **Logged in as** at the top right shows the connected username. Verify the displayed organization before collecting customer data.

Choose **Logout / clear session** or close the app to disconnect app-owned sessions and clear local reader state. Browser and OS-managed Microsoft sign-in cookies are separate.

## Microsoft 365 tools

| Tool | Data collected |
|---|---|
| Conditional Access | Nondeleted policies in all enforcement states, named locations, referenced users/groups with nested membership, application identities, roles and supported controls |
| Intune configuration | Configuration/compliance policies, applications, settings catalog metadata and optional device inventory |
| 365 security and logs | Secure Score/control profiles, MFA registration and policy evidence, and optionally retained Entra sign-in/directory-audit logs |
| Exchange and SharePoint inventory | Selected organization, authentication, transport/connector and tenant/site configuration through retained service connections |

Normal reporting is read-only. Reader roles, licensing and tenant policy determine what can be returned; missing/denied data is explicitly incomplete. MFA registration is evidence, not proof that MFA is enforced.

Use **Extended read permissions** when additional approved read permissions are needed for optional references or Intune. Connect Exchange or SharePoint separately only when needed; their sessions remain open for repeated reads until disconnect/exit. SDKs can require reauthentication after expiry or tenant-policy changes.

## Local setup and app registration

Microsoft Graph Authentication, Exchange Online and SharePoint modules must be available. If a prerequisite is missing, use the separate local setup script:

    pwsh -File .\infrastructure\Install-M365Dependencies.ps1

This installs local modules only; it does not sign in or change tenant settings. Installation may require your normal software/network permissions.

**Find reader app** uses directory reads to find an existing suitable public reader application. **Register reader app** is a separately confirmed setup write available after login. It creates a secretless public client with reviewed delegated read permissions; it does not silently grant tenant-wide consent or assign roles. An authorized administrator must review and consent needed permissions.

Use **Advanced / switch customer** only when targeting a specific different organization or a custom single-tenant app. An employee account alone cannot identify which MSP customer they intend to inspect.

See [session and setup guide](docs/M365-Session-Guide.md) and each tool's directions.txt for exact requirements and coverage.

## Reports and local log search

Every run writes report.json and report.md under a timestamped reports directory. The UI provides readable Report, Record table and JSON views. Exported evidence includes scope, UTC times, status, record IDs, limitations and instructions for an LLM. No data is automatically sent to an LLM.

Conditional Access additionally writes a self-contained conditional-access.json plus a readable overview. Join policy reference ObjectKey values to exported object Key values to resolve include/exclude scope.

For logs, enable downloading and choose the retained UTC lookback. The tool collects returned pages for Entra sign-ins and directory audits. Then **Search downloaded logs** asks for a literal issue, code, username, IP or correlation ID and searches verified local files without another login. This covers available Entra data, not unlimited history or every Microsoft 365 workload.

Collected descriptions, rules and messages are untrusted data. They cannot authorize executing commands or changing settings. Share identity, membership and network evidence only with an approved analysis service.

## Verification and extension

    pwsh -File .\tests\Test-Infrastructure.ps1
    pwsh -STA -File .\Start-PowerShellUI.ps1 -VerifyUi

Tests use synthetic data and SDK/service fixtures; they do not sign in to a customer tenant. Live account, consent, role, licensing and tenant-policy behavior still needs interactive validation by an authorized operator.

The catalog exposes only four registered Microsoft 365 report IDs. Each requires Invoke-Report.ps1, launcher.json, directions.txt and its reviewed SHA256 in infrastructure/adapters.lock.json. Unknown local scripts are not exposed. Write-capable setup is never disguised as a read-only report.
