<#
.SYNOPSIS
Reads a trace produced by tests/run.ps1.

.DESCRIPTION
Temporary development aid, to be removed with the tests/ folder.

Without -Car: the events of the scenario, the summary lines (and the GATE-TEST
lines of gate-manual) and the list of cars. With -Car: one line each time the
state of that car changes.

.EXAMPLE
tests\show.ps1 construction

.EXAMPLE
tests\show.ps1 construction -Car 132 -From 1500 -To 6000
#>
param(
	# A scenario name, or the path of a trace file.
	[Parameter(Mandatory, Position = 0)][string]$Trace,
	[int]$Car = -1,
	[int]$From = 0,
	[int]$To = [int]::MaxValue
)

$flagNames = "moving", "charging", "parking", "building", "stuck", "waiting", "empty", "maneuver", "emergency_brake", "high_speed", "precision_mode"
if (-not (Test-Path $Trace)) {
	$Trace = Join-Path (Join-Path $env:TEMP "autonomous-car-tests") "trace-$Trace.txt"
}
$lines = Get-Content $Trace
$carLine = '^(\d+) (\d+) (\S+) (\S+) \S+ (\S+) (\S+) ([01]+) a\d+ d\d+ f\S+ t(\d+) g(-?\d+) i(-?\d+) k(\S+) dst(\S+) \[(.*)\]$'

if ($Car -lt 0) {
	$lines | Where-Object { $_ -match "^(SETUP|EVENT|SELECT|SUMMARY|GATE-TEST) " }
	$cars = @{}
	foreach ($line in $lines) {
		if ($line -match $carLine) {
			$id = [int]$Matches[2]
			if (-not $cars.ContainsKey($id)) { $cars[$id] = @([int]$Matches[1], 0) }
			$cars[$id][1] = [int]$Matches[1]
		}
	}
	""
	"Cars (id: first tick - last tick):"
	$cars.GetEnumerator() | Sort-Object Name | ForEach-Object { "  {0}: {1} - {2}" -f $_.Name, $_.Value[0], $_.Value[1] }
	return
}

"  tick        x        y   speed    fuel  flags | tasks, ghosts left, items missing, detours and stuck retries, destination, alerts"
$previous = ""
foreach ($line in $lines) {
	if ($line -notmatch $carLine -or [int]$Matches[2] -ne $Car) { continue }
	$tick = [int]$Matches[1]
	if ($tick -lt $From -or $tick -gt $To) { continue }
	$bits = $Matches[7]
	$flags = @(for ($i = 0; $i -lt $bits.Length; $i++) { if ($bits[$i] -eq "1") { $flagNames[$i] } })
	$state = "{0} | t{1} g{2} i{3} k{4} dst{5} [{6}]" -f ($flags -join ","), $Matches[8], $Matches[9], $Matches[10], $Matches[11], $Matches[12], $Matches[13]
	if ($state -ne $previous) {
		"{0,6} {1,8:N2} {2,8:N2} {3,7:N3} {4,6:N0}k  {5}" -f $tick, [double]$Matches[3], [double]$Matches[4], [double]$Matches[5], ([double]$Matches[6] / 1000), $state
		$previous = $state
	}
}
