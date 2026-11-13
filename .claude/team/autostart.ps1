# Starts the lead session "IntuneChocoDeployment CTO" in the background unless it already runs.
# Run by the scheduled task from install-autostart.ps1 at sign-in. Starts nothing else.
$ErrorActionPreference = 'Stop'
$name = 'IntuneChocoDeployment CTO'
$repo = 'C:\git\IntuneChocolateyDeployment'

$json = & claude agents --json
if ($LASTEXITCODE -ne 0) { Write-Error 'claude agents --json failed'; exit 1 }
$running = @($json | ConvertFrom-Json | Where-Object { $_.name -eq $name })
if ($running.Count -gt 0) { Write-Host "$name already runs (pid $($running[0].pid))."; exit 0 }

$order = 'You are IntuneChocoDeployment CTO. Read .claude/team/README.md, .claude/team/CTO.md, the memory and the open issues. Report the state to me briefly and update your project in the Leitstelle (docs/LEITSTELLE.md of the framework), reading answered questions. Start agents only for open work that is already ordered. No release and no upload without me.'
Set-Location $repo
& claude --bg -n $name --model opus --permission-mode auto $order
exit $LASTEXITCODE
