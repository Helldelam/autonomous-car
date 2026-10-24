<#
.SYNOPSIS
Runs the test scenarios of tests/harness.lua in Factorio, without opening the game.

.DESCRIPTION
Temporary development aid, to be removed with the tests/ folder.

The script copies the mod to a temporary folder, appends tests/harness.lua to
the copy of control.lua, and runs the scenarios in Factorio's benchmark mode.
Factorio gets its own configuration and write folder there, so nothing is
written to the real Factorio folder and the game may stay open.

Every scenario of harness.lua has a category (movement, doors, robustness,
construction, energy). The scenarios of one category that are asked for run
together, in one game, each on its own surface: one Factorio launch per
category, not per scenario. A script error stops the whole category.
-Scenario takes scenario names, category names, or "all" (the default).
-Changed lists the categories that the files changed since the last commit
(git) can affect, with the command that runs each in its own folder, and runs
nothing: several categories go in parallel, one run.ps1 each.
-Set "name=value" changes a config value for the run (only values the scripts
read while playing). -Output gives the run its own folder: runs with different
folders can go at once.

A scenario runs for 22000 ticks, or for the `ticks` it declares; a category
runs as long as its longest scenario, and each scenario stops reporting at its
own end. -Ticks sets the same duration for all of them.

For each scenario it reports the exit code, any script error, the events of
the scenario and the last summary line (for gate-manual, the last position of
each subject), then the module functions that no scenario of the run called.
The full traces stay in the output folder: see tests/show.ps1. The script
exits with the number of scenarios that ended in a script error.

.EXAMPLE
tests\run.ps1
Runs every scenario (one launch per category).

.EXAMPLE
tests\run.ps1 movement
Runs the scenarios of the movement category.

.EXAMPLE
tests\run.ps1 -Changed
Lists the categories that the files changed since the last commit can affect, and the command for each (nothing runs).

.EXAMPLE
tests\run.ps1 maze, garage-exit -Ticks 8000
Runs two scenarios (two launches, as they are of different categories), for 8000 ticks each.

.EXAMPLE
tests\run.ps1 -Reference ..\autonomous-car-before
Also runs another copy of the mod (a folder or a zip) and tells whether both
produce the same traces. Use it to check that a refactoring did not change any
behaviour. The other copy runs with its own tests/harness.lua when it has one,
so the two versions may use different names. A version from before the
categories ran its scenarios one by one: traces of scenarios that shared a game
are not identical to theirs (the entities have other unit numbers).
#>
param(
	[Parameter(Position = 0)]
	[string[]]$Scenario = @("all"),
	[switch]$Changed,
	[int]$Ticks,
	[string[]]$Set = @(),
	[string]$Reference,
	[string]$Factorio = "C:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe",
	[string]$Output = (Join-Path $env:TEMP "autonomous-car-tests")
)

$ErrorActionPreference = "Stop"
$modFolder = Split-Path $PSScriptRoot -Parent

# harness.lua is the only list of scenarios: a line scenarios["name"] = {, followed by
# lines `ticks = N,` (when the scenario needs less than the default) and `category = "x",`.
$defaultTicks = 22000
$info = [ordered]@{}
$harnessText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "harness.lua"))
foreach ($match in [regex]::Matches($harnessText, '(?m)^scenarios\["([^"]+)"\] = \{((?:\r?\n[ \t]*(?:ticks|category) = [^\r\n]+,)*)')) {
	$ticksMatch = [regex]::Match($match.Groups[2].Value, 'ticks = (\d+)')
	$categoryMatch = [regex]::Match($match.Groups[2].Value, 'category = "([^"]+)"')
	if (-not $categoryMatch.Success) { throw "Scenario $($match.Groups[1].Value) of harness.lua has no category." }
	$info[$match.Groups[1].Value] = @{
		Ticks = if ($ticksMatch.Success) { [int]$ticksMatch.Groups[1].Value } else { $defaultTicks }
		Category = $categoryMatch.Groups[1].Value
	}
}
$categories = @($info.Values | ForEach-Object { $_.Category } | Select-Object -Unique)

# Which categories a changed file can affect. The Lua of the mod affects every category but
# scalability (crowd, a measurement, not a regression check): every category drives cars, visits
# chests, charges and looks for a garage (see the coverage-<category>.txt files), a script that
# creates entities shifts the unit numbers the cars are spread by, and the prototypes set how the
# cars drive and what they hold (data.lua: the charge of a full tank). Narrower for the files below;
# the other files (locale, graphics, documentation, the test scripts) affect none.
function Get-ChangedCategories {
	$files = @(git -C $modFolder diff --name-only HEAD) + @(git -C $modFolder ls-files --others --exclude-standard)
	$regression = @($categories | Where-Object { $_ -ne "scalability" })
	# Hatches and delivery chests: construction visits chests, robustness and energy remove some while
	# they are open (a drawing can cause a script error, not another trace).
	$chests = @("construction", "robustness", "energy")
	# Loading is all there is to check: the tests have no player, and harness.lua hands the selections
	# to on_area_selected itself.
	$loading = @("energy")
	$narrow = @{
		"scripts/armed.lua" = @("robustness") # only acts after Military
		"scripts/chest.lua" = $chests
		"scripts/gui.lua" = $loading
		"scripts/game_trace.lua" = $loading
		"prototypes/shortcuts.lua" = $loading
		"prototypes/corpse.lua" = $loading
		"info.json" = $loading
	}
	$picked = @()
	foreach ($file in $files) {
		if ($narrow.ContainsKey($file)) { $picked += $narrow[$file] }
		elseif ($file -like "scripts/*.lua" -or $file -like "prototypes/*.lua" -or $file -in @("control.lua", "config.lua", "data.lua", "tests/harness.lua")) { $picked += $regression }
	}
	return @($categories | Where-Object { $picked -contains $_ })
}

$requested = @()
if ($Changed) {
	# Runs nothing: a run of several categories goes one run.ps1 per category, in parallel, each in its
	# own folder (see "Tests lourds" in CLAUDE.md); this one would run them one after the other.
	$changedCategories = Get-ChangedCategories
	if ($changedCategories.Count -eq 0) {
		Write-Host "No changed file affects a category: nothing to run."
		exit 0
	}
	Write-Host "Changed files affect: $($changedCategories -join ', '). One command per category (in parallel when there are several):"
	foreach ($category in $changedCategories) {
		Write-Host "  tests\run.ps1 $category -Output `$env:TEMP\autonomous-car-changed\$category"
	}
	exit 0
}
foreach ($item in $Scenario) {
	if ($item -eq "all") { $requested += @($info.Keys) }
	elseif ($categories -contains $item) { $requested += @($info.Keys | Where-Object { $info[$_].Category -eq $item }) }
	elseif ($info.Contains($item)) { $requested += $item }
	else { throw "Unknown scenario or category: $item. Scenarios of harness.lua: $(@($info.Keys) -join ', '). Categories: $($categories -join ', ')." }
}
$requested = @($info.Keys | Where-Object { $requested -contains $_ }) # harness order, once each
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
	robocopy $source $target /MIR /XD tests .github .git /NFL /NDL /NJH /NJS /NP | Out-Null
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

# Runs scenarios together in one game, on one version of the mod, and collects the output
# files. A version from before the categories (its harness has no SCENARIOS) runs them one by one.
# Returns the exit code, the stdout file, the coverage file and a trace file per scenario.
function Invoke-Group($mod, [string]$variant, [string]$label, [string[]]$names, [int]$duration) {
	if (-not $mod.Harness.Contains("SCENARIOS")) {
		$traces = @{}
		$worst = 0
		foreach ($name in $names) {
			$single = Invoke-Legacy $mod $variant $name $duration
			$traces[$name] = $single.Trace
			if ($single.ExitCode -ne 0) { $worst = $single.ExitCode }
		}
		return @{ ExitCode = $worst; Stdout = $single.Stdout; Coverage = $single.Coverage; Traces = $traces }
	}
	$control = [IO.File]::ReadAllText($mod.Source)
	$tickOverride = if ($Ticks -gt 0) { "$Ticks" } else { "nil" }
	$header = "`nlocal SCENARIOS = `"$($names -join ',')`"`nlocal TICKS = $tickOverride`n"
	# -Set "friction.slow=6": a config value changed for this run (only values the scripts read while running)
	foreach ($assignment in $Set) {
		$header += "require(`"config`").$assignment`n"
	}
	[IO.File]::WriteAllText($mod.Control, $control + $header + $mod.Harness)

	foreach ($stale in Get-ChildItem $scriptOutput -Filter "*.txt" -ErrorAction SilentlyContinue) {
		Move-Item $stale.FullName "$($stale.FullName).stale" -Force
	}
	$suffix = if ($variant -eq "current") { $label } else { "$label-$variant" }
	$result = @{
		Coverage = Join-Path $Output "coverage-$suffix.txt"
		Stdout = Join-Path $Output "stdout-$suffix.txt"
		Traces = @{}
	}
	$result.ExitCode = Start-Factorio $mod.Mods @("--benchmark", "`"$mapFile`"", "--benchmark-ticks", $duration, "--disable-audio") $result.Stdout
	foreach ($name in $names) {
		$kept = Join-Path $Output $(if ($variant -eq "current") { "trace-$name.txt" } else { "trace-$name-$variant.txt" })
		$produced = Join-Path $scriptOutput "trace-$name.txt"
		if (Test-Path $produced) { Move-Item $produced $kept -Force } elseif (Test-Path $kept) { Move-Item $kept "$kept.stale" -Force }
		$result.Traces[$name] = $kept
	}
	$produced = Join-Path $scriptOutput "coverage.txt"
	if (Test-Path $produced) { Move-Item $produced $result.Coverage -Force } elseif (Test-Path $result.Coverage) { Move-Item $result.Coverage "$($result.Coverage).stale" -Force }
	return $result
}

# The way a version from before the categories ran one scenario (SCENARIO, trace.txt).
function Invoke-Legacy($mod, [string]$variant, [string]$name, [int]$duration) {
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

function Write-GroupReport([string]$label, $names, $result) {
	$status = if ($result.ExitCode -eq 0) { "ok" } else { "FAILED (exit code $($result.ExitCode))" }
	Write-Host ""
	Write-Host "#### $label ($($names.Count) scenario(s)): $status ####"
	$stdout = @(Get-Content $result.Stdout)
	$errorAt = ($stdout | Select-String -Pattern "Error while running|Error while loading|Failed to load mod" | Select-Object -First 1)
	if ($errorAt) {
		$first = $errorAt.LineNumber - 1
		$stdout[$first..([Math]::Min($first + 6, $stdout.Count - 1))] | ForEach-Object { Write-Host "  $_" }
	}
}

function Write-Report([string]$name, [string]$trace) {
	$lines = @()
	if (Test-Path $trace) { $lines = @(Get-Content $trace) }
	Write-Host ""
	Write-Host "== $name : $($lines.Count) trace lines =="
	$lines | Where-Object { $_ -match "^(SETUP|EVENT|SELECT|BATCH) " } | ForEach-Object { Write-Host "  $_" }
	# gate-manual has no tracked car: its result is the last position of each subject.
	$lines | Where-Object { $_ -match "^GATE-TEST " } | Group-Object { ($_ -split " ")[2] } |
		ForEach-Object { Write-Host "  $($_.Group[-1])" }
	$summary = $lines | Where-Object { $_ -match "^SUMMARY " } | Select-Object -Last 1
	if ($summary) { Write-Host "  $summary" }
}

# Adds the call counts of one launch to the totals of the whole run.
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
foreach ($category in $categories) {
	$names = @($requested | Where-Object { $info[$_].Category -eq $category })
	if ($names.Count -eq 0) { continue }
	$duration = if ($PSBoundParameters.ContainsKey("Ticks")) { $Ticks } else { ($names | ForEach-Object { $info[$_].Ticks } | Measure-Object -Maximum).Maximum }
	$result = Invoke-Group $current "current" $category $names $duration
	Write-GroupReport $category $names $result
	foreach ($name in $names) { Write-Report $name $result.Traces[$name] }
	Add-Coverage $callCounts $result.Coverage
	if ($result.ExitCode -ne 0) { $failed += $names.Count }
	if ($referenceMod) {
		$referenceResult = Invoke-Group $referenceMod "reference" $category $names $duration
		foreach ($name in $names) {
			Write-Host "  $name vs the reference:"
			if ((Test-Path $result.Traces[$name]) -and (Test-Path $referenceResult.Traces[$name])) {
				Compare-Traces $result.Traces[$name] $referenceResult.Traces[$name]
			} else {
				Write-Host "  no trace to compare (reference exit code $($referenceResult.ExitCode))"
			}
		}
	}
}
# register_release_handler only runs while control.lua loads, before the counters exist.
$neverCalled = @($callCounts.Keys | Where-Object { $callCounts[$_] -eq 0 -and $_ -ne "_utils.register_release_handler" } | Sort-Object)
Write-Host ""
Write-Host "Module functions never called in this run ($($neverCalled.Count)): $($neverCalled -join ', ')"
Write-Host "$($requested.Count - $failed) of $($requested.Count) scenario(s) ran without a script error."
Write-Host "Traces and Factorio output: $Output"
exit $failed
