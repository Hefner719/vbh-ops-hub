<#
  vbh-backup.ps1 - take a restorable copy of the hub's data.

  WHY: Supabase's free tier keeps its own daily snapshots, but they are not
  listed through the API, not downloadable, and point-in-time recovery is off.
  Until that changes there is no copy of this data that Van Buskirk Homes
  controls. This makes one.

  Writes timestamped JSON, one file per table, to
      <OneDrive>\VBH-Hub-Backups\yyyy-MM-dd_HHmm\
  OneDrive keeps its own version history, so the copy is itself protected.

    tools\vbh-backup.ps1                  # full backup, prune older than 30 days
    tools\vbh-backup.ps1 -KeepDays 90
    tools\vbh-backup.ps1 -Quiet           # for scheduled runs
    tools\vbh-backup.ps1 -Install         # register a daily 6pm scheduled task
    tools\vbh-backup.ps1 -Status          # is it scheduled, did it run, how old

  Restoring: each file is a JSON array of rows exactly as PostgREST returned
  them. `tools\vbh-restore-preview.ps1` shows what a file would put back.
#>
param(
  [int]$KeepDays = 30,
  [switch]$Quiet,
  [switch]$Install,
  [switch]$Status,
  [string]$Destination
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Say($m, $c = 'Gray') { if (-not $Quiet) { Write-Host $m -ForegroundColor $c } }

# ── register a daily task and exit ─────────────────────────────────────────
# A plain `schtasks /SC DAILY` fires at 6pm or not at all: if the laptop is off,
# asleep or shut for the day at that moment, that day has no backup and nothing
# says so. StartWhenAvailable runs the missed one at the next opportunity
# instead, which is the behaviour this actually needs on a machine that travels.
if ($Install) {
  $me = $MyInvocation.MyCommand.Path
  $name = 'VBH Hub Backup'
  try {
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                 -Argument ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$me`" -Quiet")
    $trigger = New-ScheduledTaskTrigger -Daily -At '6:00PM'
    $set     = New-ScheduledTaskSettingsSet -StartWhenAvailable `
                 -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
                 -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
                 -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger `
                           -Settings $set -Principal $principal -Force | Out-Null
    $t = Get-ScheduledTask -TaskName $name
    Write-Host "Registered `"$name`" - daily at 6:00 PM, catches up a missed run." -ForegroundColor Green
    Write-Host ("State: {0}   Next run: {1}" -f $t.State, (Get-ScheduledTaskInfo -TaskName $name).NextRunTime)
  } catch {
    # Older boxes without the ScheduledTasks module still get a working task.
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$me`" -Quiet"
    schtasks /Create /TN $name /TR $cmd /SC DAILY /ST 18:00 /F | Out-Null
    Write-Host "Registered `"$name`" via schtasks (no catch-up for missed runs)." -ForegroundColor Yellow
  }
  Write-Host 'Check it ran:   tools\vbh-backup.ps1 -Status'
  Write-Host 'Remove it with: schtasks /Delete /TN "VBH Hub Backup" /F'
  exit 0
}

# ── report whether backups are actually happening ──────────────────────────
# The point of this switch: for three weeks the task did not exist and nothing
# anywhere said so. A backup you have not checked is not a backup.
if ($Status) {
  $name = 'VBH Hub Backup'
  $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if (-not $task) {
    Write-Host "NOT SCHEDULED - no `"$name`" task on this machine." -ForegroundColor Red
    Write-Host 'Register it with:  tools\vbh-backup.ps1 -Install'
  } else {
    $info = Get-ScheduledTaskInfo -TaskName $name
    $res  = if ($info.LastTaskResult -eq 0) { 'OK' } else { "exit $($info.LastTaskResult)" }
    $col  = if ($info.LastTaskResult -eq 0) { 'Green' } else { 'Red' }
    Write-Host ("Task: {0}   Last run: {1} ({2})   Next: {3}" -f $task.State, $info.LastRunTime, $res, $info.NextRunTime) -ForegroundColor $col
  }
  $od = $env:OneDriveCommercial; if (-not $od) { $od = $env:OneDrive }
  if (-not $od) { $od = Join-Path $env:USERPROFILE 'Documents' }
  $dir = Join-Path $od 'VBH-Hub-Backups'
  $runs = Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_\d{4}$' } | Sort-Object Name -Descending
  if (-not $runs) { Write-Host "No backups in $dir" -ForegroundColor Red; exit 1 }
  $newest = [datetime]::ParseExact($runs[0].Name, 'yyyy-MM-dd_HHmm', $null)
  $age = [int]((Get-Date) - $newest).TotalHours
  $c = if ($age -le 30) { 'Green' } elseif ($age -le 72) { 'Yellow' } else { 'Red' }
  Write-Host ("Newest backup: {0}  ({1} hours ago)   {2} kept" -f $runs[0].Name, $age, $runs.Count) -ForegroundColor $c
  $runs | Select-Object -First 5 | ForEach-Object {
    $man = Join-Path $_.FullName 'manifest.json'
    $rows = '?'; $kind = '?'
    if (Test-Path $man) { try { $j = Get-Content $man -Raw | ConvertFrom-Json
                                $rows = ($j.tables | Measure-Object -Property Rows -Sum).Sum
                                $kind = $j.key_kind } catch {} }
    Write-Host ("  {0}  {1,6} rows  ({2})" -f $_.Name, $rows, $kind)
  }
  exit 0
}

# ── where ──────────────────────────────────────────────────────────────────
if (-not $Destination) {
  $od = $env:OneDriveCommercial; if (-not $od) { $od = $env:OneDrive }
  if (-not $od) { $od = Join-Path $env:USERPROFILE 'Documents' }
  $Destination = Join-Path $od 'VBH-Hub-Backups'
}
$stamp  = Get-Date -Format 'yyyy-MM-dd_HHmm'
$outDir = Join-Path $Destination $stamp
New-Item -ItemType Directory -Force $outDir | Out-Null

# ── credentials: the service role, so row-level security cannot hide rows ──
# Falls back to the anon key if no service key is stored; that still works
# today but will return nothing once the Phase B lockdown is in force.
$svcFile = Join-Path $env:USERPROFILE '.vbh\supabase_service_key.txt'
$base    = 'https://bppirsahciuxrqzitfxa.supabase.co/rest/v1'
if (Test-Path $svcFile) {
  $key = (Get-Content $svcFile -Raw).Trim()
  $keyKind = 'service role'
} else {
  $cfg = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'public\vbh-config.js') -Raw
  $key = [regex]::Match($cfg, "SUPABASE_KEY:\s*'([^']+)'").Groups[1].Value
  $keyKind = 'anon (limited)'
}
if (-not $key) { throw 'No Supabase key available.' }
$hdr = @{ apikey = $key; Authorization = "Bearer $key" }

# work_orders was dropped 2026-10-05 with the development-maintenance side of
# the business (migration 022); its 34 rows live in
# archive/work-orders-retired-2026-10-05/. Left in this list it would fail the
# backup every night.
$tables = @('projects','project_updates','leads','meetings','assets','action_items',
            'profiles','vbh_role_seed','bt_emails','bt_events','bt_ingest_runs')

Say ''
Say "VBH hub backup - $stamp  (key: $keyKind)" 'Cyan'
Say "  -> $outDir"
Say ''

$summary = @()
$failed  = 0
foreach ($t in $tables) {
  try {
    # Page with limit/offset. `Range` is a restricted header in .NET and cannot
    # be set through Invoke-RestMethod, so use PostgREST's query parameters.
    # An explicit order makes paging deterministic; tables keyed by something
    # other than `id` are listed here.
    $orderBy = switch ($t) { 'vbh_role_seed' { 'email' } default { 'id' } }
    $rows = New-Object System.Collections.ArrayList
    $from = 0; $page = 1000
    while ($true) {
      $uri = "$base/$t`?select=*&order=$orderBy&limit=$page&offset=$from"
      $batch = Invoke-RestMethod -Uri $uri -Headers $hdr -Method Get
      if (-not $batch -or @($batch).Count -eq 0) { break }
      [void]$rows.AddRange(@($batch))
      if (@($batch).Count -lt $page) { break }
      $from += $page
    }
    # ConvertTo-Json on an empty collection yields $null, which Set-Content
    # refuses; write a real empty array so every table produces a file.
    $json = if ($rows.Count -eq 0) { '[]' } else { $rows | ConvertTo-Json -Depth 12 }
    $path = Join-Path $outDir "$t.json"
    Set-Content -Path $path -Value $json -Encoding UTF8
    $kb = [Math]::Round((Get-Item $path).Length / 1KB, 1)
    $summary += [pscustomobject]@{ Table = $t; Rows = $rows.Count; KB = $kb }
    $flag = if ($rows.Count -eq 0 -and $keyKind -ne 'service role') { '  (empty - needs the service key)' } else { '' }
    Say ("  {0,-18} {1,6} rows  {2,8} KB{3}" -f $t, $rows.Count, $kb, $flag)
  } catch {
    $failed++
    Say ("  {0,-18} FAILED: {1}" -f $t, $_.Exception.Message) 'Red'
  }
}

# ── manifest, so a restorer knows what they are looking at ─────────────────
@{
  taken_at   = (Get-Date).ToString('o')
  project    = 'bppirsahciuxrqzitfxa'
  key_kind   = $keyKind
  tables     = $summary
  failed     = $failed
  note       = 'JSON arrays of rows as returned by PostgREST. Restore with care: check for id collisions first.'
} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir 'manifest.json') -Encoding UTF8

if ($keyKind -ne 'service role') {
  Say ''
  Say 'NOTE: running with the anon key, so any table it cannot read backs up empty.' 'Yellow'
  Say '      After the Phase B lockdown that will be most of them. Store the service' 'Yellow'
  Say '      role key (Supabase > Settings > API) at:' 'Yellow'
  Say ("      " + (Join-Path $env:USERPROFILE '.vbh\supabase_service_key.txt')) 'Yellow'
}
$total = ($summary | Measure-Object -Property Rows -Sum).Sum
Say ''
if ($failed) { Say "$failed table(s) failed - backup is INCOMPLETE." 'Red' }
else         { Say "$total rows across $($summary.Count) tables." 'Green' }

# ── prune ──────────────────────────────────────────────────────────────────
$cutoff = (Get-Date).AddDays(-$KeepDays)
$old = Get-ChildItem $Destination -Directory -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_\d{4}$' -and $_.CreationTime -lt $cutoff }
if ($old) {
  $old | Remove-Item -Recurse -Force
  Say "Pruned $($old.Count) backup(s) older than $KeepDays days."
}
Say ''
if ($failed) { exit 1 }
