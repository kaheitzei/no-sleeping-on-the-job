# Regenerates install.ps1 from hooks\*.ps1 + install.ps1.template.
# Run this after editing anything in hooks\.
$ErrorActionPreference = 'Stop'

$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'install.ps1.template'))
foreach ($name in 'common', 'keep-awake', 'prevent-sleep', 'allow-sleep') {
  $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot "hooks\$name.ps1"))
  $placeholder = '__{0}_B64__' -f $name.ToUpper().Replace('-', '_')
  if (-not $template.Contains($placeholder)) { throw "Placeholder $placeholder missing from template" }
  $template = $template.Replace($placeholder, [Convert]::ToBase64String($bytes))
}

$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($template, [ref]$null, [ref]$errors)
if ($errors) { throw "install.ps1 does not parse: $($errors[0].Message)" }

$out = Join-Path $PSScriptRoot 'install.ps1'
[IO.File]::WriteAllText($out, $template, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Wrote install.ps1 ($((Get-Item $out).Length) bytes)"
