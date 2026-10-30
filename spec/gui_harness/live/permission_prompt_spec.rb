# frozen_string_literal: false

require 'spec_helper'
require 'open3'

# The examples ask the PowerShell script about a run that is held up by a permission.
#
# The installer of Ableton asks for permission before it registers the file types of Live, and
# the prompt is on the secure desktop, where nothing of the session can reach it. Live waits
# for the permission, and a set is not loaded until it is given.
RSpec.describe 'the permission prompt of the PowerShell script' do
  # The path of the PowerShell script of the Live layer.
  #
  # @return [String] the path
  def script_path
    File.expand_path '../../../assets/live/run.ps1', __dir__
  end

  # Runs an expression against the PowerShell script of the Live layer.
  #
  # The script is dot-sourced, so that its functions are there without the script launching
  # anything. The parameters of the script are given, because they are mandatory.
  #
  # @param expression [String] the PowerShell expression to run
  # @return [String] the output of the expression
  def powershell(expression)
    script = GuiHarness::Live::Launcher.windows_path script_path
    command = ". '#{script}' -Exe notepad.exe -Set C:/missing.txt; #{expression}"
    output, = Open3.capture2e 'powershell.exe', '-NoProfile', '-Command', command
    output
  end

  it 'holds Live up when the installer is asking for permission' do
    expression = "$prompt = [pscustomobject]@{ MainWindowTitle = 'InstallHelper.exe is requesting your permission' }; " \
                 "Test-WaitsForPermission 'C:/ProgramData/Ableton/Live 11 Suite/Program/Ableton Live 11 Suite.exe' @($prompt)"

    expect(powershell(expression).strip).to eq('True')
  end

  it 'does not hold Live up when there is no prompt' do
    expression = "Test-WaitsForPermission 'C:/ProgramData/Ableton/Live 11 Suite/Program/Ableton Live 11 Suite.exe' @()"

    expect(powershell(expression).strip).to eq('False')
  end

  it 'does not hold another program up' do
    expression = "$prompt = [pscustomobject]@{ MainWindowTitle = 'InstallHelper.exe is requesting your permission' }; " \
                 "Test-WaitsForPermission 'C:/Windows/System32/notepad.exe' @($prompt)"

    expect(powershell(expression).strip).to eq('False')
  end

  it 'finds only the prompts of the installer of Ableton' do
    expression = "@(Get-PermissionPrompts) | Where-Object { $_.MainWindowTitle -notmatch 'InstallHelper' } | " \
                 'Measure-Object | Select-Object -ExpandProperty Count'

    expect(powershell(expression).strip.to_i).to eq(0)
  end

  it 'does not start Live while the installer is asking for permission' do
    # The program is one that is not there, so that a run that starts it anyway fails without
    # starting anything.
    expression = "$prompt = [pscustomobject]@{ MainWindowTitle = 'InstallHelper.exe is requesting your permission' }; " \
                 "$process = Start-Application 'C:/nowhere/Ableton Live 11 Suite.exe' @() 'normal' @($prompt); " \
                 "if ($null -eq $process) { 'not started' } else { 'started' }"

    expect(powershell(expression).strip).to eq('not started')
  end

  it 'starts the program when there is no prompt' do
    expression = "$process = Start-Application 'C:/Windows/System32/notepad.exe' @() 'normal' @(); " \
                 "if ($null -eq $process) { 'not started' } else { Stop-Process -Id $process.Id -Force; 'started' }"

    expect(powershell(expression).strip).to eq('started')
  end
end
