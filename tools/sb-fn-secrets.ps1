<#
  sb-fn-secrets.ps1 - push Edge Function secrets from a local env file.

  The file lives OUTSIDE the repo and is never printed:
      %USERPROFILE%\.vbh\bt-graph.env
  One KEY=VALUE per line, # comments allowed. Expected keys:
      GRAPH_TENANT_ID=...
      GRAPH_CLIENT_ID=...
      GRAPH_CLIENT_SECRET=...
      GRAPH_MAILBOX=jordan.hefner@vanbuskirkco.com
      GRAPH_FOLDER=Buildertrend
      BT_CRON_SECRET=...           (any long random string; also goes in bt_settings.cron_secret)

  Usage:
    tools\sb-fn-secrets.ps1                # push every key in the file
    tools\sb-fn-secrets.ps1 -Only BT_CRON_SECRET
    tools\sb-fn-secrets.ps1 -List          # show which secret NAMES exist on the project
#>
param([string]$EnvFile = (Join-Path $env:USERPROFILE '.vbh\bt-graph.env'), [string[]]$Only, [switch]$List, [string]$ProjectRef = 'bppirsahciuxrqzitfxa')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$pat = (Get-Content (Join-Path $env:USERPROFILE '.vbh\supabase_pat.txt') -Raw).Trim()
$hdr = @{ Authorization = "Bearer $pat" }
$uri = "https://api.supabase.com/v1/projects/$ProjectRef/secrets"

if ($List) {
  $cur = Invoke-RestMethod -Uri $uri -Headers $hdr
  if (-not $cur) { "no custom secrets set"; return }
  $cur | ForEach-Object { "  " + $_.name }
  return
}

if (-not (Test-Path $EnvFile)) { throw "No env file at $EnvFile" }
$pairs = @()
foreach ($line in Get-Content $EnvFile) {
  $l = $line.Trim()
  if (-not $l -or $l.StartsWith('#')) { continue }
  $i = $l.IndexOf('=')
  if ($i -lt 1) { throw "Bad line in env file (expected KEY=VALUE): $($l.Substring(0,[Math]::Min(20,$l.Length)))..." }
  $k = $l.Substring(0, $i).Trim(); $v = $l.Substring($i + 1).Trim().Trim('"')
  if ($Only -and ($Only -notcontains $k)) { continue }
  if (-not $v) { throw "Empty value for $k" }
  $pairs += @{ name = $k; value = $v }
}
if (-not $pairs.Count) { throw "Nothing to push." }

$body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @($pairs) -Compress))
Invoke-RestMethod -Uri $uri -Method Post -Headers $hdr -ContentType 'application/json' -Body $body | Out-Null
"Pushed $($pairs.Count) secret(s): " + (($pairs | ForEach-Object { $_.name }) -join ', ')
"Redeploy or wait ~1 min for running instances to pick them up."
