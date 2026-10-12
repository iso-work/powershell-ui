# PowerShell UI

Windows desktop launcher for a directory of PowerShell scripts. No web server or third-party modules are required.

## Start

From Windows PowerShell 5.1 or PowerShell 7 on Windows:

```powershell
.\Start-PowerShellUI.ps1
# Optional external script directory:
.\Start-PowerShellUI.ps1 -ScriptsRoot C:\MyScripts
```

Use your organization's normal script signing and execution policy. The launcher does not bypass execution policy.

## Add scripts

Put scripts in subdirectories anywhere below the repository root (or ScriptsRoot):

```text
scripts/
  Reporting/
    Get-Report.ps1
    Get-Report.txt
  Maintenance/
    Cleanup.ps1
    usage.txt
```

Discovery is recursive. Root-level launcher scripts, infrastructure, tests, .git, and directory junctions/symlinks are excluded. For each .ps1, a matching basename .txt takes precedence over usage.txt in the same directory. Missing documentation is shown in the interface. Click Refresh scripts after adding or changing files.

The text file is human-readable guidance, displayed verbatim. Suggested sections: USAGE, PARAMETERS, EXPECTED OUTPUT. It does not execute instructions or automatically assert results.

Select a script, read Usage and expected output, open Parameters, enter values, then Run. Switch parameters have checkboxes; other declared script parameters have text inputs. Empty inputs omit the parameter, preserving script defaults. PowerShell performs parameter conversion and validation. Arrays, credentials, secure strings, dynamic parameters, and interactive prompts are not supported by this first version. Missing mandatory values fail in the noninteractive worker and appear in Results.

## Execution

Scripts run locally under the current user's permissions, in their own directory, using the same PowerShell executable as the launcher. They can access local systems and networks just like a script you run manually. Only run trusted scripts.

Results show captured PowerShell output and errors after completion, with an exit code. The interface remains responsive during execution. Stop terminates the worker process; it does not roll back changes or guarantee termination of programs the script started. GUI scripts and scripts requiring console interaction are unsuitable for this runner. Output is buffered in memory; use file output for very large reports.

## Verify

```powershell
.\tests\Test-Infrastructure.ps1
```

The example script is safe and demonstrates parameters, a switch, and expected output. Actual administrative scripts can be added later.
