settings\  -  what the Settings tab saved
=================================================================

settings.json is written by the Settings tab (Save settings) and read at
every start: its values are laid over the defaults in lib\01-Config.ps1.
It holds only what differs from those defaults:

  * the pre-action confirmations: which products are used here (VMware
    snapshot, Trellix Solidcore Update Mode, Airlock, any other step),
    so which Yes/No pop-ups come before every install and removal
  * change records: the change management system, the fields that must
    be filled in, and per action - change record required, a change
    record or a maintenance activity, or not recorded
  * the running log: command and reasoning lines, size, log retention
  * warnings, safety limits and Health thresholds

Change it on the Settings tab rather than by hand: every value is
checked there, and every change is written to the log with who made it.
A hand edit that does not fit is skipped at start-up with a warning in
the log, and the default stays.  Delete the file to go back to the
defaults.

software-shown.json (beside it) holds the packages the Software console
shows when the library has more than MaxSoftwareColumns - chosen in its
Software library window.  Delete it to show the first packages by name.

patch-runs.json (beside it) is the tool's note of every OS patch run it
has handed to a server as a SYSTEM task and not recorded yet: server,
run stamp, KBs, files, who, when, the change record.  The O/S Patching
grid shows those rows as INSTALLING from it, also after a restart, and
nothing else is installed on such a server until a status check has
read the result from it.  Written and cleared by the tool; delete it
only if a server's run is certainly over and the row will not clear
(a status check or "Analyse a failure" normally does that).

spoke.json (beside it) is written by Start-WinRMToolkit.ps1 -Spoke on a
server the hub cannot reach over WinRM: the hub folder (the toolkit
folder of the hub, a share or a copy, holding patches\ and software\)
and the results folder (where that copy writes its results file).  The
spoke asks for both at every start and offers these as the answers.

settings\*.json is git-ignored: it describes YOUR environment.
