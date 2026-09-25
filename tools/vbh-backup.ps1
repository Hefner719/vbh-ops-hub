<#
  vbh-backup.ps1 · take a restorable copy of the hub's data.

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

  Restoring: each file is a JSON array of rows exactly as PostgREST returned
  them. `tools\vbh-restore-preview.ps1` shows what a file would put back.
#>
param(
  [int]$KeepDays = 30,
  [switch]$Quiet,
  [switch]$Install,
  [string]$Destination
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Say($m, $c = 'Gray') { if (-not $Quiet) { Write-Host $m -ForegroundColor $c } }

# ── register a daily task and exit ─────────────────────────────────────────
if ($Install) {
  $me = $MyInvocation.MyCommand.Path
  $action = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$me`" -Quiet"
  schtasks /Create /TN 'VBH Hub Backup' /TR $action /SC DAILY /ST 18:00 /F | Out-Null
  Write-Host 'Registered "VBH Hub Backup" — runs daily at 6:00 PM.' -ForegroundColor Green
  Write-Host 'Remove it with:  schtasks /Delete /TN "VBH Hub Backup" /F'
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

$tables = @('projects','project_updates','leads','meetings','work_orders','assets',
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
