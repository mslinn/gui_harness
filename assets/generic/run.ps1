<#
  The generic entry point of the GUI harness.

  This is the script the Ruby layer runs. It holds the parameters of the run and nothing else:
  the functions live in the library, which is loaded after the parameters are read, so that the
  library cannot reset them.
#>
param(
  [Parameter(Mandatory=$true)][string]$Exe,
  [Parameter(Mandatory=$true)][string]$Set,
  [string]$Log = '',
  [string]$SavePath = '',
  [switch]$SaveInPlace,
  [string]$PidFile = '',
  [int]$TimeoutSeconds = 5,
  [ValidateSet('normal','minimized','hidden')][string]$Visibility = 'normal',
  [string]$ShutdownRungs = 'close_windows,wait_for_exit,stop_tree',
  [switch]$HarnessDebug
)

if ($HarnessDebug) { $env:GUI_HARNESS_DEBUG = '1' }

. (Join-Path $PSScriptRoot 'gui_harness_generic.ps1')

if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }
