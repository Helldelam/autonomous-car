<#
.SYNOPSIS
Runs the test scenarios of tests/harness.lua in Factorio, without opening the game.

.DESCRIPTION
Temporary development aid, to be removed with the tests/ folder.

The script copies the mod to a temporary folder, appends tests/harness.lua to
the copy of control.lua, and runs each scenario in Factorio's benchmark mode.
Factorio gets its own configuration and write folder there, so nothing is
written to the real Factorio folder and the game may stay open.

The scenarios are those of tests/harness.lua, in the order of that file. Each
runs for 22000 ticks, or for the `ticks` it declares there; -Ticks sets the
same duration for all of them.

For each scenario it reports the exit code, any script error, the events of
the scenario and the last summary line (for gate-manual, the last position of
each subject), then the module functions that no scenario of the run called.
The full traces stay in the output folder: see tests/show.ps1. The script
exits with the number of scenarios that ended in a script error.

.EXAMPLE
tests\run.ps1
Runs every scenario.

.EXAMPLE
tests\run.ps1 construction, garage-exit -Ticks 8000
Runs two scenarios, for 8000 ticks each.

.EXAMPLE
tests\run.ps1 -Reference ..\autonomous-car-before
Also runs another copy of the mod (a folder or a zip) and tells whether both
produce the same traces. Use it to check that a refactoring did not change any
behaviour. The other copy runs with its own tests/harness.lua when it has one,
so the two versions may use different names.
#>
param(
	[Parameter(Position = 0)]
	[string[]]$Scenario = @("all"),
	[int]$Ticks,
	[string]$Reference,
	[string]$Factorio = "C:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe",
	[string]$Output = (Join-Path $env:TEMP "autonomous-car-tests")
)

$ErrorActionPreference = "Stop"
$modFolder = Split-Path $PSScriptRoot -Parent

# harness.lua is the only list of scenarios: a line scenarios["name"] = {,
# followed by a line `ticks = N,` when the scenario needs less than the default.
$defaultTicks = 22000
$scenarioTicks = [ordered]@{}
$harnessText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "harness.lua"))
foreach ($match in [regex]::Matches($harnessText, '(?m)^scenarios\["([^"]+)"\] = \{(?:\s*ticks = (\d+),)?')) {
	$scenarioTicks[$match.Groups[1].Value] = if ($match.Groups[2].Success) { [int]$match.Groups[2].Value } else { $defaultTicks }
}
if ($Scenario -contains "all") {
	$Scenario = @($scenarioTicks.Keys)
}
$unknown = @($Scenario | Where-Object { -not $scenarioTicks.Contains($_) })
if ($unknown.Count -gt 0) {
	throw "Unknown scenario: $($unknown -join ', '). Scenarios of harness.lua: $(@($scenarioTicks.Keys) -join ', ')."
}
if (-not (Test-Path $Factorio)) {
	throw "Factorio not found at '$Factorio'. Pass its path with -Factorio."
}

$modName = (Get-Content (Join-Path $modFolder "info.json") -Raw | ConvertFrom-Json).name
$writeFolder = Join-Path $Output "write"
$scriptOutput = Join-Path $writeFolder "script-output"
$configFile = Join-Path $Output "config.ini"
$mapFile = Join-Path $writeFolder "test-map.zip"
New-Item -ItemType Directory -Force $writeFolder | Out-Null
[IO.File]::WriteAllText($configFile, "; version=12`n[path]`nread-data=__PATH__executable__/../../data`nwrite-data=$($writeFolder -replace '\\', '/')`n")

# Copies one version of the mod (a folder or a zip) to its own mod directory.
function Install-Mod([string]$variant, [string]$source) {
	if ($source -like "*.zip") {
		$unzipped = Join-Path $Output "unzipped-$variant"
		Expand-Archive $source $unzipped -Force
		$source = $unzipped
	}
	$modsFolder = Join-Path $Output "mods-$variant"
	$target = Join-Path $modsFolder $modName
	robocopy $source $target /MIR /XD tests .backup .github .git /NFL /NDL /NJH /NJS /NP | Out-Null
	if ($LASTEXITCODE -ge 8) {
		throw "Could not copy '$source' to '$target' (robocopy exit code $LASTEXITCODE)."
	}
	$modList = '{"mods":[{"name":"base","enabled":true},{"name":"' + $modName + '","enabled":true}]}'
	[IO.File]::WriteAllText((Join-Path $modsFolder "mod-list.json"), $modList)
	# A version that has its own harness runs with it: names may differ from one version to the other.
	$harnessFile = Join-Path $source "tests\harness.lua"
	if (-not (Test-Path $harnessFile)) { $harnessFile = Join-Path $PSScriptRoot "harness.lua" }
	return @{
		Mods = $modsFolder
		Control = (Join-Path $target "control.lua")
		Source = (Join-Path $source "control.lua")
		Harness = [IO.File]::ReadAllText($harnessFile)
	}
}

function Start-Factorio([string]$modsFolder, [string[]]$arguments, [string]$stdoutFile) {
	$all = @("--config", "`"$configFile`"", "--mod-directory", "`"$modsFolder`"") + $arguments
	$process = Start-Process $Factorio -ArgumentList $all -Wait -PassThru -RedirectStandardOutput $stdoutFile
	return $process.ExitCode
}

# Runs one scenario on one version of the mod and collects its output files.
function Invoke-Scenario($mod, [string]$variant, [string]$name, [int]$duration) {
	$control = [IO.File]::ReadAllText($mod.Source)
	[IO.File]::WriteAllText($mod.Control, $control + "`nlocal SCENARIO = `"$name`"`n" + $mod.Harness)

	foreach ($file in "trace.txt", "coverage.txt") {
		$stale = Join-Path $scriptOutput $file
		if (Test-Path $stale) { Move-Item $stale "$stale.stale" -Force }
	}
	$suffix = if ($variant -eq "current") { $name } else { "$name-$variant" }
	$result = @{
		Trace = Join-Path $Output "trace-$suffix.txt"
		Coverage = Join-Path $Output "coverage-$suffix.txt"
		Stdout = Join-Path $Output "stdout-$suffix.txt"
	}
	$result.ExitCode = Start-Factorio $mod.Mods @("--benchmark", "`"$mapFile`"", "--benchmark-ticks", $duration, "--disable-audio") $result.Stdout
	foreach ($file in "trace", "coverage") {
		$produced = Join-Path $scriptOutput "$file.txt"
		$kept = $result[$file.Substring(0, 1).ToUpper() + $file.Substring(1)]
		if (Test-Path $produced) { Move-Item $produced $kept -Force } elseif (Test-Path $kept) { Move-Item $kept "$kept.stale" -Force }
	}
	return $result
}

function Write-Report([string]$name, $result) {
	$lines = @()
	if (Test-Path $result.Trace) { $lines = @(Get-Content $result.Trace) }
	$status = if ($result.ExitCode -eq 0) { "ok" } else { "FAILED (exit code $($result.ExitCode))" }
	Write-Host ""
	Write-Host "== $name : $status, $($lines.Count) trace lines =="

	$stdout = @(Get-Content $result.Stdout)
	$errorAt = ($stdout | Select-String -Pattern "Error while running|Error while loading|Failed to load mod" | Select-Object -First 1)
	if ($errorAt) {
		$first = $errorAt.LineNumber - 1
		$stdout[$first..([Math]::Min($first + 6, $stdout.Count - 1))] | ForEach-Object { Write-Host "  $_" }
	}

	$lines | Where-Object { $_ -match "^(SETUP|EVENT|SELECT|BATCH) " } | ForEach-Object { Write-Host "  $_" }
	# gate-manual has no tracked car: its result is the last position of each subject.
	$lines | Where-Object { $_ -match "^GATE-TEST " } | Group-Object { ($_ -split " ")[2] } |
		ForEach-Object { Write-Host "  $($_.Group[-1])" }
	$summary = $lines | Where-Object { $_ -match "^SUMMARY " } | Select-Object -Last 1
	if ($summary) { Write-Host "  $summary" }
}

# Adds the call counts of one scenario to the totals of the whole run.
function Add-Coverage($totals, [string]$coverageFile) {
	if (-not (Test-Path $coverageFile)) { return }
	foreach ($line in Get-Content $coverageFile) {
		$name, $count = $line -split "\s+"
		if ($name) { $totals[$name] = [int]$totals[$name] + [int]$count }
	}
}

function Compare-Traces([string]$current, [string]$reference) {
	$a = @(Get-Content $current)
	$b = @(Get-Content $reference)
	for ($i = 0; $i -lt [Math]::Max($a.Count, $b.Count); $i++) {
		if ($a[$i] -ne $b[$i]) {
			Write-Host "  DIFFERENT from the reference, first at line $($i + 1):"
			Write-Host "    current:   $($a[$i])"
			Write-Host "    reference: $($b[$i])"
			return
		}
	}
	Write-Host "  identical to the reference ($($a.Count) lines)"
}

$current = Install-Mod "current" $modFolder
$referenceMod = $null
if ($Reference) {
	$referenceMod = Install-Mod "reference" (Resolve-Path $Reference).Path
}

# A fixed seed keeps the natural terrain of the "basics" scenario the same from one run to the next.
$created = Start-Factorio $current.Mods @("--create", "`"$mapFile`"", "--map-gen-seed", "1") (Join-Path $Output "stdout-create.txt")
if ($created -ne 0) {
	Get-Content (Join-Path $Output "stdout-create.txt") | Select-Object -Last 15 | ForEach-Object { Write-Host $_ }
	throw "Factorio could not load the mod and create the test map (exit code $created)."
}

$failed = 0
$callCounts = @{}
foreach ($name in $Scenario) {
	$duration = if ($PSBoundParameters.ContainsKey("Ticks")) { $Ticks } else { $scenarioTicks[$name] }
	$result = Invoke-Scenario $current "current" $name $duration
	Write-Report $name $result
	Add-Coverage $callCounts $result.Coverage
	if ($result.ExitCode -ne 0) { $failed++ }
	if ($referenceMod) {
		$referenceResult = Invoke-Scenario $referenceMod "reference" $name $duration
		if ((Test-Path $result.Trace) -and (Test-Path $referenceResult.Trace)) {
			Compare-Traces $result.Trace $referenceResult.Trace
		} else {
			Write-Host "  no trace to compare (reference exit code $($referenceResult.ExitCode))"
		}
	}
}
# register_release_handler only runs while control.lua loads, before the counters exist.
$neverCalled = @($callCounts.Keys | Where-Object { $callCounts[$_] -eq 0 -and $_ -ne "_utils.register_release_handler" } | Sort-Object)
Write-Host ""
Write-Host "Module functions never called in this run ($($neverCalled.Count)): $($neverCalled -join ', ')"
Write-Host "$($Scenario.Count - $failed) of $($Scenario.Count) scenario(s) ran without a script error."
Write-Host "Traces and Factorio output: $Output"
exit $failed
