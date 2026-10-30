# frozen_string_literal: false

require 'spec_helper'
require 'open3'

# The examples ask the PowerShell script about a run that is held up by a permission.
#
# The installer of Ableton asks for permission before it registers the file types of Live, and
# the prompt is on the secure desktop, where nothing of the session can reach it. Live waits
# for the permission, and a set is not loaded until it is given.
RSpec.describe 'the permission prompt of the PowerShell script' do
  # The path of the PowerShell script of the launcher.
  #
  # @return [String] the path
  def script_path
    File.expand_path '../../assets/gui_harness_live_launcher.ps1', __dir__
  end

  # Runs an expression against the PowerShell script of the launcher.
  #
  # The script is dot-sourced, so that its functions are there without the script launching
  # anything. The parameters of the script are given, because they are mandatory.
  #
  # @param expression [String] the PowerShell expression to run
  # @return [String] the output of the expression
  def powershell(expression)
    script = GuiHarness::LiveLauncher.windows_path script_path
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
end
