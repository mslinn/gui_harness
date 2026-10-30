# frozen_string_literal: false

require 'spec_helper'
require 'open3'

# The examples ask the PowerShell script about the ladder Live is shut down by.
#
# Ruby holds the order of the rungs, and PowerShell holds the mechanics of each rung. The
# ladder of Live is the ladder of the generic layer with the rungs of Live put in.
RSpec.describe GuiHarness::Live::Shutdown do
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

  it 'holds the rungs of the Live ladder' do
    expect(described_class::RUNGS).to eq(%i[close_windows answer_save_prompt wait_for_exit confirm_clean_exit
                                            stop_tree])
  end

  it 'is the ladder the Live launcher hands to the sidecar' do
    expect(GuiHarness::Live::Launcher.shutdown_rungs).to eq(described_class::RUNGS)
  end

  it 'holds the rungs of the generic layer as well' do
    expect(described_class::RUNGS).to include(*GuiHarness::Generic::Shutdown::RUNGS)
  end

  it 'has the rungs of the Live layer in the sidecar' do
    expect(powershell('(Get-Command answer_save_prompt -ErrorAction SilentlyContinue) -ne $null').strip).to eq('True')
    expect(powershell('(Get-Command confirm_clean_exit -ErrorAction SilentlyContinue) -ne $null').strip).to eq('True')
  end

  it 'climbs the rungs of the Live layer' do
    expression = '$context = New-RunContext -LogStart 0; ' \
                 "$context.ShutdownRungs = @('close_windows', 'answer_save_prompt', 'wait_for_exit', " \
                 "'confirm_clean_exit', 'stop_tree'); " \
                 '$context.Process = $null; ' \
                 'Invoke-ShutdownLadder $context; ' \
                 "'gone=' + $context.ApplicationGone + ' ' + " \
                 "'clean=' + $context.CleanExitConfirmed"
    expect(powershell(expression).strip).to eq('gone=True clean=True')
  end
end
