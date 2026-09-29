param([string]$Exe)
$psi = New-Object System.Diagnostics.ProcessStartInfo $Exe
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
$p = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Milliseconds 500
$a = $p.TotalProcessorTime; Start-Sleep -Seconds 3; $p.Refresh(); $b = $p.TotalProcessorTime
"idle cpu ms over 3 s: {0:N0}" -f ($b - $a).TotalMilliseconds
$p.StandardInput.Close(); [void]$p.WaitForExit(2000)
