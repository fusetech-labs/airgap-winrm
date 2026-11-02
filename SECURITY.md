# Security policy

## Reporting a vulnerability

Please do not open a public GitHub issue for a security problem. Write to products@fusetech.com.au instead.

Include what you can of the following:

- the version of the toolkit (the About tab shows it) and which script or console is affected;
- what the problem lets someone do, and who could do it (an operator, a user on a managed server, someone on
  the network);
- steps to reproduce, or the lines of code involved;
- any log lines from `logs\` that show it (remove host names and account names first if you need to);
- how you would like to be credited, if at all.

We will acknowledge your report within 5 business days and tell you what we intend to do and when. We ask that
you give us a reasonable time to fix the problem before you publish anything about it.

## Scope

The toolkit is the PowerShell scripts in this repository (`Start-WinRMToolkit.ps1`, `lib\`) and the data files
under `data\`. Problems in Windows, WinRM, DISM or third-party products the toolkit talks to belong with their
own vendors, but tell us if the toolkit makes such a problem worse.

## No network calls, no telemetry

The toolkit makes no network calls other than WinRM to the servers in your group files. Nothing is downloaded,
nothing is sent to Fusetech or anyone else, and no usage data is collected, so there is no telemetry to disclose.
Reports stay in the `reports\` folder on the toolkit PC.

## Code signing

Every published script is meant to be signed with your organisation's code-signing certificate before it is used
(README.txt and the README say how). A script whose signature does not verify should not be run.
