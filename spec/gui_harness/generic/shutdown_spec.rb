# frozen_string_literal: false

require 'spec_helper'
require 'open3'

# The examples ask the PowerShell script about the ladder the generic layer is shut down by.
#
# Ruby holds the order of the rungs, and PowerShell holds the mechanics of each rung. A rung
# that the layer does not have is not climbed.
RSpec.describe GuiHarness::Generic::Shutdown do
  # The path of the PowerShell script of the generic layer.
  #
  # @return [String] the path
  def script_path
    File.expand_path '../../../assets/generic/run.ps1', __dir__
  end

  # Runs an expression against the PowerShell script of the generic layer.
  #
  # The script is dot-sourced, so that its functions are there without the script launching
  # anything. The parameters of the script are given, because they are mandatory.
  #
  # @param expression [String] the PowerShell expression to run
  # @return [String] the output of the expression
  def powershell(expression)
    script = GuiHarness::Generic::Launcher.windows_path script_path
    command = ". '#{script}' -Exe notepad.exe -Set C:/missing.txt; #{expression}"
    output, = Open3.capture2e 'powershell.exe', '-NoProfile', '-Command', command
    output
  end

  it 'holds the rungs of the generic ladder' do
    expect(described_class::RUNGS).to eq(%i[close_windows wait_for_exit stop_tree])
  end

  it 'is the ladder the generic launcher hands to the sidecar' do
    expect(GuiHarness::Generic::Launcher.shutdown_rungs).to eq(described_class::RUNGS)
  end

  it 'holds no rung of the Live layer' do
    expect(described_class::RUNGS).not_to include(:answer_save_prompt)
    expect(described_class::RUNGS).not_to include(:confirm_clean_exit)
  end

  it 'has no rung of the Live layer in the sidecar' do
    expect(powershell('(Get-Command answer_save_prompt -ErrorAction SilentlyContinue) -eq $null').strip).to eq('True')
    expect(powershell('(Get-Command confirm_clean_exit -ErrorAction SilentlyContinue) -eq $null').strip).to eq('True')
  end

  it 'does not climb a rung the layer does not have' do
    expression = '$context = New-RunContext -LogStart 0; ' \
                 "$context.ShutdownRungs = @('answer_save_prompt', 'close_windows', 'wait_for_exit'); " \
                 '$context.Process = $null; ' \
                 'Invoke-ShutdownLadder $context; ' \
                 "'gone=' + $context.ApplicationGone"
    expect(powershell(expression).strip).to eq('gone=True')
  end

  it 'does not fail over a rung that is of no account to any layer' do
    expression = '$context = New-RunContext -LogStart 0; ' \
                 "$context.ShutdownRungs = @('no_such_rung'); " \
                 'Invoke-ShutdownLadder $context; ' \
                 "'climbed'"
    expect(powershell(expression).strip).to eq('climbed')
  end
end
