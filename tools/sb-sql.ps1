<#
  sb-sql.ps1 - run SQL against the VBH Supabase project via the Management API.

  Auth: a Supabase personal access token read from a file OUTSIDE the repo:
        %USERPROFILE%\.vbh\supabase_pat.txt   (one line, the token, nothing else)
  Create one at https://supabase.com/dashboard/account/tokens - name it "claude-code sb-sql".
  The token is never printed and never written anywhere else.

  Usage:
    tools\sb-sql.ps1 -File supabase\migrations\001_bt_bridge.sql
    tools\sb-sql.ps1 -Query "select event_type, count(*) from bt_events group by 1 order by 2 desc"
    tools\sb-sql.ps1 -Query "..." -Json      # raw JSON instead of a table
#>
param(
  [string]$File,
  [string]$Query,
  [switch]$Json,
  [string]$ProjectRef = 'bppirsahciuxrqzitfxa'
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$patPath = Join-Path $env:USERPROFILE '.vbh\supabase_pat.txt'
if (-not (Test-Path $patPath)) { throw "No token at $patPath. Create a personal access token at https://supabase.com/dashboard/account/tokens and save it there (single line)." }
$pat = (Get-Content $patPath -Raw).Trim()
if (-not $pat) { throw "Token file is empty: $patPath" }

if ($File) {
  if (-not (Test-Path $File)) { throw "File not found: $File" }
  # .NET read, not Get-Content -Raw: PS 5.1 attaches note properties to that string and
  # ConvertTo-Json then serializes it as {"value":...} instead of a plain string.
  $sql = [IO.File]::ReadAllText((Resolve-Path $File).Path, [Text.Encoding]::UTF8)
} elseif ($Query) {
  $sql = [string]$Query
} else { throw "Pass -File or -Query." }

$uri  = "https://api.supabase.com/v1/projects/$ProjectRef/database/query"
$body = @{ query = $sql } | ConvertTo-Json -Compress -Depth 3
$bytes = [Text.Encoding]::UTF8.GetBytes($body)
try {
  $resp = Invoke-RestMethod -Uri $uri -Method Post -Headers @{ Authorization = "Bearer $pat" } -ContentType 'application/json; charset=utf-8' -Body $bytes
} catch {
  $detail = ''
  if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
  elseif ($_.Exception.Response) {
    try { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $detail = $sr.ReadToEnd() } catch {}
  }
  # The API returns Postgres errors as JSON {message, ...}; surface them readably.
  try { $j = $detail | ConvertFrom-Json; if ($j.message) { $detail = "Postgres: $($j.message)" + $(if ($j.hint) { " (hint: $($j.hint))" }) } } catch {}
  throw "Supabase query failed: $($_.Exception.Message)`n$detail"
}

if ($Json) { $resp | ConvertTo-Json -Depth 8; return }
if ($null -eq $resp) { "OK (no rows)"; return }
if ($resp -is [array] -and $resp.Count -eq 0) { "OK (0 rows)"; return }
$resp | Format-Table -AutoSize | Out-String -Width 220
