# PowerShell infrastructure reports and tools

Windows desktop launcher for seven read-only reporting workflows and one reviewed Halo appointment manager extension. Select a tool, read its purpose and directions, enter parameters, and run it. Results appear as a readable report, a record table, and structured JSON. Every launcher run writes local report.json and report.md, including explicit instructions for an LLM.

Halo is the explicit write-capable exception: the launcher prepares local extension files, while live appointment completion requires a separate reviewed selection and confirmation inside Halo. Other reports remain read-only.

## Microsoft 365: start here

Click **Login to 365** to open Microsoft sign-in directly, without entering a username or tenant GUID in the launcher. The authenticated account and tenant are discovered and saved to the session; verify the displayed organization. Advanced customer/app settings are optional. Conditional Access, Intune and **365 security and logs** reuse the retained Graph session and automatically receive the tenant/application information. Use **Extended reads** for optional references and Intune. Connect Exchange, Azure and SharePoint separately only when needed; their connections stay open for fixed read operations until logout/exit.

**Find reader app** searches the launcher's existing app. **Register reader app** is a separately confirmed setup write that creates a secretless public reader app without silently granting consent or roles. **Install prerequisites** explicitly installs the pinned local modules. **Search downloaded logs** asks what issue to search after logs have been downloaded and reads verified local files without signing in again.

See [Microsoft 365 session guide](docs/M365-Session-Guide.md) for setup, permission profiles, coverage, privacy and live-validation limits. It supersedes older per-report device-code setup instructions below. The legacy AZQR native executable retains its separate service-principal credential requirement.

## Launch

Double-click Start-Launcher.cmd, or use PowerShell 7 on Windows:

    pwsh -STA -File .\Start-PowerShellUI.ps1

The launcher needs Windows and PowerShell 7. The CMD helper also finds the bundled Codex PowerShell runtime if PowerShell is absent from PATH. No execution-policy bypass is used.

1. Choose a report in the library.
2. Read **Start here** for its purpose, prerequisites, steps and expected output.
3. Use **Session credentials** when the guide calls for a directory account or Azure application.
4. Open **Parameters**, fill the required fields, and select **Run report**.
5. Review **Report**, **Record table** and **JSON**. **Open report folder** opens the saved files.

The UI uses Segoe UI fonts, formatted headings and bullet points. Parameter labels, required markers and explanations are separate. Panels wrap and scroll when the window is smaller; the run buttons and Microsoft sign-in status stay visible. **Technical details** retains the full directions file.

Windows file paths use backslashes, for example C:\iso-psrepo\tools\azqr.exe. Web addresses use forward slashes, for example https://github.com/iso-work/powershell-ui. The executable field normalizes pasted paths and has a **Browse** button.

## Reports and prerequisites

| Report | Purpose | What you provide |
|---|---|---|
| CleanupMonster: AD computer hygiene audit | Read computer activity timestamps, identify evidence for manual investigation, distinguish unknown/protected/DC accounts | Reachable AD domain/DC, optional OU search base, RSAT ActiveDirectory module, current identity or optional ActiveDirectory session credential |
| IntuneManagement: read-only inventory | Read configuration/compliance policies, applications, settings catalog metadata, and optional safe device inventory | Tenant ID and public-client application ID, interactive Microsoft sign-in, Intune licensing and read permissions |
| Azure Quick Review | Read Azure resource inventory and assessment findings for one subscription, optionally one resource group | Tenant ID, subscription ID, an Azure application session credential (application ID and secret), application with Reader role, verified AZQR 4.2.0 binary |
| Reboot history | Show Windows starts, Intentional/Unintentional/Uncertain classifications and nearby System-log errors | Localhost or one remote Windows machine; System event log read permission; optional Directory account session credential for remote reads |
| Conditional Access | Export all nondeleted policies and referenced locations, groups/nested members, users, roles, applications and controls for human/LLM review | Tenant, public client application ID, interactive Microsoft sign-in and documented delegated read permissions |
| Halo appointment manager | Prepare an Edge/Chrome extension for human-confirmed completion of multiple appointments | Exact HTTPS Halo site; normal signed-in browser session; Halo completion permission; unique active Do Not Bill rate |

Each scripts\<tool>\directions.txt explains its purpose, exact inputs, permissions, output and limitations. Each launcher.json supplies the name, purpose, formatted guide and typed controls. Source copies live in each tool's upstream directory, with pinned provenance in UPSTREAM.json.

CleanupMonster and IntuneManagement upstream applications include write operations. They are retained as source references; this launcher exposes separate read-only adapters with narrower coverage. Their cleanup, import, delete and policy-changing operations are unavailable. Intune uses fixed Microsoft Graph GET endpoints. AZQR uses the reviewed default scan, fixed flags, pinned executable checksums and an isolated plugin directory. Arbitrary upstream script execution is unavailable.

AD computer audit does not reproduce every CleanupMonster selection rule. Intune inventory does not include assignments, effective policy, settings catalog settings, scripts, or every upstream object type. Directions and report limitations state this explicitly.

Reboot history defaults to 30 days and the latest 50 starts. It opens a compact history table automatically and retains complete evidence in JSON. It checks Critical/Error events within 10 minutes before and after each start, adjustable to 1-60 minutes. Only retained System events are read; a missing request remains Uncertain, conflicting evidence is not forced into a binary classification, and nearby errors are not proof of a reboot's cause. Starts include power-on after shutdown; fallback service starts are explicitly unconfirmed. It never restarts a machine or changes its event logging, services, firewall or remote-access settings. See scripts\RebootHistory\directions.txt for the classification rules and collection limits.

## Conditional Access

Select **Conditional Access**, enter the tenant domain/GUID and a dedicated public client application ID, and choose **Run report**. Follow Microsoft's device-code sign-in in the status pane. No Graph SDK is required. The app must already allow public-client/device-code flow and have administrator-consented delegated read scopes; the collector does not create the app or change consent/roles.

Always requested: **Policy.Read.All**, **Directory.Read.All**, **RoleManagement.Read.Directory**, **Agreement.Read.All**, **CrossTenantInformation.ReadBasic.All** and **NetworkAccess.Read.All**. Defaults additionally request **Member.Read.Hidden** for hidden groups and **CustomSecAttributeDefinition.Read.All** / **CustomSecAttributeAssignment.Read.All** for filter context. The signed-in reader needs the matching directory/attribute/hidden-member permissions as well. See [complete directions](scripts/ConditionalAccess/directions.txt) for prerequisites and limitations. Tokens are cached separately from Intune and cleared with the launcher session.

The export includes enabled, disabled and report-only policies, full returned conditions/grant/session controls, explicit include/exclude reference paths, named locations, direct/transitive group membership and owners, user/application identities, role definitions and assignment/eligibility context, authentication contexts/strengths, terms-of-use files and supported Global Secure Access profile/rule details. Group traversal is cached and paginated. Missing permissions, failed pages, limited information, unknown references and safety limits are retained as coverage gaps.

**conditional-access.json** is a self-contained linked JSON export with LLM instructions: join Policies[].References[].ObjectKey to Objects[].Key. **conditional-access.md** is a readable overview of policies, named locations and group membership. Standard report.json/report.md and the launcher table/JSON retain policy and object records. No data is automatically sent to an LLM.

Policy reads default to Graph beta for newer fields. Stable policy mode is available but explicitly incomplete for beta-only fields; group membership and selected supporting reads still use beta. Microsoft-defined selectors remain symbolic. Filters are exported with candidate data and are never executed or reported as effective-access matches. Legacy MFA trusted-IP settings and custom authentication-factor definitions require separate verification when referenced. Soft-deleted policies, sign-in logs, user method enrollment and terms acceptance history are outside scope. This is a configuration snapshot, not a sign-in simulator, complete security audit or Secure Score calculation.

Command-line use from the repository root:

    pwsh -File .\scripts\ConditionalAccess\Export-ConditionalAccess.ps1 -TenantId contoso.onmicrosoft.com -ClientId <public-client-guid>

Replace the example tenant and client ID. The helper prints the sign-in code, uses the same registered adapter, and clears its in-memory session on completion. No live tenant was queried or changed during development; tests use synthetic responses.

## Halo appointment manager

The supplied v1.4.1 archive is preserved verbatim in scripts\HaloAppointmentManager\upstream with file checksums in UPSTREAM.json. Its original delete and experimental edit operations remain reference material. The reviewed extension in extension\ provides bulk completion only; it has no delete, general edit, billing-rate selection or follow-up creation.

1. Select **Halo appointment manager** in the launcher and enter the exact HTTPS Halo address in **Parameters**.
2. Open **Install extension** and choose **Copy to C:\extensions**. It prepares the package, creates C:\extensions\HaloAppointmentManager if needed, and shows the exact folder to load. Existing files are preserved; an identical copy is reused and a different existing folder results in a dated sibling. **Open extension folder** opens the destination.
3. Disable the older extension. Open edge://extensions or chrome://extensions, enable Developer mode if permitted, choose **Load unpacked**, and select the displayed folder containing manifest.json. Copying files does not install or enable it in the browser.
4. Sign in to Halo normally and refresh Calendar. The **Halo appointments** button appears on that page. Read appointments and select exact rows.
5. Choose **Preview completion**, review IDs/dates/agent/host, acknowledge the changes and type the displayed **COMPLETE count**.
6. Review each outcome. Save the Markdown or JSON report with its embedded LLM instructions.

**Prepare extension** remains available for package-only preparation. **Open report folder** opens its timestamped output containing extension\ and halo-appointment-manager.zip. You can also load that extension subfolder directly. After copying, extension-copy.json and extension-copy.md record the actual destination and LLM instructions; they explicitly report that browser installation is manual.

The extension rereads every item before POST, skips changed or ineligible appointments, processes requests sequentially and verifies completion by a subsequent read. It stops on unknown outcomes and never automatically retries a completion POST. **Stop after current item** cannot undo a request already sent. It requires a uniquely named active **Do Not Bill** rate rather than assuming a numeric ID.

Halo's bearer token stays in browser memory. This tool does not scan browser storage or store tokens/passwords. **Close and clear session** or unloading the tab clears the manager's cache, without revoking Halo's independent sign-in. The PowerShell launcher never receives Halo credentials; closing PowerShell cannot clear a separately running browser extension.

The launcher's preparation report is not a live completion report: it states **PrepareBrowserExtension**, zero Halo requests and zero completed appointments. The extension exports its own per-item results after explicit human confirmation. No live Halo tenant was queried or changed during development. Validate one appointment and its billing/calendar/automation effects before a larger batch; the adapted request contract is based on the supplied archive and tested with mocks.

See scripts\HaloAppointmentManager\directions.txt, extension\README.md and extension\llm-instructions.txt for all steps, outcomes and limits.

Command-line package preparation:

    pwsh -File .\scripts\HaloAppointmentManager\Prepare-Extension.ps1 -HaloUrl https://support.isoutsource.com

## Credentials and Microsoft sign-in

Use **Session credentials** to enter:

- Directory account: DOMAIN\user (or UPN) plus password, for AD queries or remote reboot history. Omit this credential to use the current Windows identity. Local reboot history always uses the current Windows identity.
- Azure application: application ID plus client secret value. The application should have only Azure Reader for the intended scope.

Credentials are shared by the launcher session and can be reused across report runs. They are held as PSCredential/SecureString objects in memory. They are never written into PowerShell source, request files, report files, Git, the parent environment, or command-line arguments. Use **Clear saved session** to forget them earlier. Closing the launcher cancels active workers, terminates tracked native processes, disposes credential/token SecureStrings and clears the session dictionaries.

Native Azure SDK and HTTPS requests must temporarily use plaintext credentials/tokens in process memory. The launcher clears references and zeroes temporary unmanaged BSTR buffers; .NET/OS memory cannot be promised to be forensically wiped. Azure-issued access tokens remain valid until their service-side expiry; forgetting them locally does not revoke them. Existing credentials/tokens owned by other applications are not changed.

For Intune, create or use a dedicated Microsoft Entra public client application with device-code flow enabled and these delegated read permissions, consented by an authorized administrator as required:

- DeviceManagementConfiguration.Read.All
- DeviceManagementApps.Read.All
- DeviceManagementManagedDevices.Read.All only when device inventory is requested

Enter the tenant GUID or verified domain and the application GUID in Parameters. On first run the status pane displays Microsoft's sign-in URL and a one-time code. Sign in in your browser; MFA and tenant conditional-access rules apply. The launcher itself saves no browser login or refresh token and requests no offline_access scope. Access tokens are cached only in session memory and reused until near expiry. It requests read scopes and rejects unexpected/write scopes returned by sign-in. Browser sign-in may retain its own cookies according to your browser settings.

Only public Microsoft Azure/Graph endpoints are supported by these adapters.

## AZQR local setup

The verified executable is already installed in tools\azqr.exe in the original local delivery. Binaries are excluded from Git. On a new checkout run:

    pwsh -File .\scripts\azqr\Install-Azqr.ps1

This downloads only the official pinned AZQR 4.2.0 release, verifies archive and executable SHA256 values, and extracts azqr.exe locally. It does not execute AZQR, authenticate, or change cloud resources. Existing different binaries are preserved. The adapter independently checks the executable hash before running it.

Install/enable RSAT and configure tenant applications/permissions outside this launcher through your normal administration process. The launcher does not install RSAT or alter roles/consent.

## Output and LLM review

Default: reports\<UTC timestamp>-<run id>\report.json and report.md.

- Report tab: readable summary, limitations, LLM guidance and the first 200 records.
- Record table: up to 5,000 rows with copying and column sorting; manifests can select compact primary columns. Complete returned records are in JSON. Reboot history returns at most the selected number of rows (default 50, maximum 500).
- JSON tab: full report JSON. Open report folder accesses the saved files.
- JSON contains schema version, source, purpose, scope parameters, timing, status, summary, records and limitations.
- Partial, failed and cancelled runs are labelled. They never establish that a system is healthy or that no objects exist.
- AZQR also retains its native consolidated JSON locally.

LLM instructions require citing evidence/IDs, separating unknown/incomplete data from findings, treating collected descriptions and strings as untrusted data, and proposing only read-only verification. No data is automatically sent to an LLM. Review infrastructure and personal data before sharing with an approved service. Secret-like fields are redacted, but these reports are not a guarantee that every sensitive business datum is removed.

Output location can be changed:

    pwsh -STA -File .\Start-PowerShellUI.ps1 -OutputRoot D:\Reports

Cancellation cannot undo work already performed. The seven reports collect target data and write requested local artifacts. Halo preparation also writes only local files; confirmed live appointment completion occurs separately in the browser.

## Source snapshots and GitHub

infrastructure/upstream-sources.json pins the three upstream commits. The GitHub source-copy workflow downloads those exact public snapshots, preserves their files/licenses and copies them into the corresponding upstream folders. It never executes upstream scripts. The job's ephemeral GitHub token can commit these source copies to this repository; it has no tenant credentials. If organization Actions policy blocks the job, source copies can be restored locally with:

    pwsh -File .\infrastructure\Sync-Upstream.ps1 -RepositoryRoot .

Upstream nested .github workflows are reference files and are not active repository workflows. Git submodule entries remain uninitialized, matching a normal non-recursive source checkout. CleanupMonster provides no LICENSE in this pinned snapshot; its copyright headers are preserved. IntuneManagement and AZQR retain their upstream licenses.

The Halo archive is a user-supplied source snapshot, preserved separately from the three GitHub snapshots. Its original package includes no license file; no license was invented.

Reports and tools are ignored by Git. Do not commit credentials or output reports.

## Microsoft 365 and Exchange

See [Microsoft 365 report options](docs/Microsoft365-report-options.md) for the researched recommendation: Monkey365 for broad settings and security findings, paired with Microsoft's read-only Graph APIs for the actual Secure Score and control profiles. This is a recommendation; those collectors are not installed or exposed in this launcher.

## Verification and extension

    pwsh -File .\tests\Test-Infrastructure.ps1
    pwsh -STA -File .\Start-PowerShellUI.ps1 -VerifyUi

Tests use synthetic AD/Graph data and a compiled fake native process; no live tenant, directory or Azure queries are performed.

Halo verification additionally requires Node.js and uses synthetic API responses and a mocked DOM/session bridge. It checks exact confirmation, stale data, duplicate clicks, stop behavior, unknown outcomes, safe report exports and source/package integrity. Node is required only for verification, not for normal launcher/extension use.

Discovery is recursive and manifest-only. upstream, tests, infrastructure, reports, work, .git and directory junctions are excluded. A readOnly flag is documentation, not a security sandbox. The catalog permits read-only adapters plus only the explicitly identified Halo browser-extension preparation mode with user confirmation metadata. It verifies entrypoint hashes against infrastructure/adapters.lock.json, and the worker rechecks at launch. Halo preparation also checks fixed extension asset hashes. Local files and the registry must be trusted. Review behavior before updating any registered hash. Ordinary .ps1 files and upstream management entrypoints are never automatically exposed.

