# Pattern Detective Windows worker update

This package contains a narrow source delta and a guarded update command. It
does not contain the full installed worker, credentials, model files, call
recordings, or customer data. It applies only to the Windows Stage 5 worker
captured on Nov 23, 2026. The installed file must have SHA-256
`6c6f968054f7a08d83a4011f862189ee79402fc219a2b79f5d6e48f8beebfce5`.
The expected updated SHA-256 is
`a8ca1e9152b8cc36fc9271559382075a11d0829375b9bb10ebad4698bf05863e`.

Run these commands **on the authorized Windows worker host**, from this package
directory, in a PowerShell session that can inspect and control its scheduled
tasks. First check the installation and read-only lease probe:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Update-PatternWorker.ps1
```

Then run the update:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Update-PatternWorker.ps1 -Apply
```

The script derives the install root from the **AIHelper Stage 5 AI Worker**
task's launcher path and working directory, then checks any supplied
`-InstallRoot` against that task. A relative launcher needs a task working
directory. If the task uses `pythonw.exe`, also pass
`-PythonExe` with the Python executable from the same environment. It refuses
an unfamiliar task action, an installed file with a different hash, missing
Pattern Detective dependencies, or an unavailable read-only database probe.

The update creates a timestamped local backup, stages and syntax checks the
new file, waits for an idle heartbeat and zero active worker leases, disables
only the AI worker task, swaps one file atomically, and restarts that task. It
checks for a fresh worker heartbeat and reports whether the pattern pipeline
has been observed. Continuous priority work can delay that observation, so
`worker_running_pattern_check_pending` is a provisional result. The reported
pattern job count covers the whole database, not just this worker. Check the AI
Team page for a current saved scan. On worker verification failure, the script restores the baseline
from its backup when no new lease is active. If safe rollback cannot complete,
it preserves the backup and reports `rollback=incomplete_backup_preserved`.

The original worker has no quiesce handshake, so a new job can begin in the
small interval between the final idle probe and Task Scheduler stopping it.
The script checks again immediately after stopping and aborts if it observes
that race. Database leases and retries remain authoritative; never clear jobs
or delete saved evidence to force a rollout.

The script does not change the gateway, database schema, source worker, call
intake task, portal, or private configuration. Pin the public repository to a
reviewed commit before running its code on the worker host.
