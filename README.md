# Read-only PowerShell infrastructure reports

Windows desktop launcher for three reviewed reporting workflows. Select a report, read its purpose and directions, enter scope parameters, and run it. Results appear as a readable report, a record table, and structured JSON. Every run writes local report.json and report.md, including explicit instructions for an LLM.

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

Each scripts\<tool>\directions.txt explains its purpose, exact inputs, permissions, output and limitations. Each launcher.json supplies the name, purpose, formatted guide and typed controls. Source copies live in each tool's upstream directory, with pinned provenance in UPSTREAM.json.

CleanupMonster and IntuneManagement upstream applications include write operations. They are retained as source references; this launcher exposes separate read-only adapters with narrower coverage. No cleanup, import, delete, policy changes, remediation or arbitrary upstream script execution is available from the UI. Intune uses fixed Microsoft Graph GET endpoints. AZQR uses the reviewed default scan, fixed flags, pinned executable checksums and an isolated plugin directory.

AD computer audit does not reproduce every CleanupMonster selection rule. Intune inventory does not include assignments, effective policy, settings catalog settings, scripts, or every upstream object type. Directions and report limitations state this explicitly.

## Credentials and Microsoft sign-in

Use **Session credentials** to enter:

- Directory account: DOMAIN\user (or UPN) plus password. Omit this credential to use the current Windows identity.
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
- Record table: up to 5,000 rows with copying and column sorting; complete data is in JSON.
- JSON tab: full report JSON. Open report folder accesses the saved files.
- JSON contains schema version, source, purpose, scope parameters, timing, status, summary, records and limitations.
- Partial, failed and cancelled runs are labelled. They never establish that a system is healthy or that no objects exist.
- AZQR also retains its native consolidated JSON locally.

LLM instructions require citing evidence/IDs, separating unknown/incomplete data from findings, treating collected descriptions and strings as untrusted data, and proposing only read-only verification. No data is automatically sent to an LLM. Review infrastructure and personal data before sharing with an approved service. Secret-like fields are redacted, but these reports are not a guarantee that every sensitive business datum is removed.

Output location can be changed:

    pwsh -STA -File .\Start-PowerShellUI.ps1 -OutputRoot D:\Reports

Cancellation cannot undo work already performed. These reviewed adapters only collect target data and write requested local artifacts; no remediation is performed.

## Source snapshots and GitHub

infrastructure/upstream-sources.json pins the three upstream commits. The GitHub source-copy workflow downloads those exact public snapshots, preserves their files/licenses and copies them into the corresponding upstream folders. It never executes upstream scripts. The job's ephemeral GitHub token can commit these source copies to this repository; it has no tenant credentials. If organization Actions policy blocks the job, source copies can be restored locally with:

    pwsh -File .\infrastructure\Sync-Upstream.ps1 -RepositoryRoot .

Upstream nested .github workflows are reference files and are not active repository workflows. Git submodule entries remain uninitialized, matching a normal non-recursive source checkout. CleanupMonster provides no LICENSE in this pinned snapshot; its copyright headers are preserved. IntuneManagement and AZQR retain their upstream licenses.

Reports and tools are ignored by Git. Do not commit credentials or output reports.

## Microsoft 365 and Exchange

See [Microsoft 365 report options](docs/Microsoft365-report-options.md) for the researched recommendation: Monkey365 for broad settings and security findings, paired with Microsoft's read-only Graph APIs for the actual Secure Score and control profiles. This is a recommendation; those collectors are not installed or exposed in this three-report launcher.

## Verification and extension

    pwsh -File .\tests\Test-Infrastructure.ps1
    pwsh -STA -File .\Start-PowerShellUI.ps1 -VerifyUi

Tests use synthetic AD/Graph data and a compiled fake native process; no live tenant, directory or Azure queries are performed.

Discovery is recursive and manifest-only. upstream, tests, infrastructure, reports, work, .git and directory junctions are excluded. A readOnly flag is documentation, not a security sandbox. The catalog also verifies adapter entrypoint hashes against infrastructure/adapters.lock.json, and the worker rechecks at launch. Local files and the registry must be trusted. Review any adapter change for read-only behavior before updating its registered hash. Ordinary .ps1 files and upstream management entrypoints are never automatically exposed.

