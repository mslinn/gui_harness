# frozen_string_literal: false

require 'spec_helper'
require 'open3'
require 'tempfile'

# The examples ask the PowerShell script what it makes of Live's log.
#
# The dialogs of Live are Qt windows that UI Automation sees nothing in, so the log is where
# they are read from. The log is stood in for by a file the examples write, and the run state
# is filled in from it.
RSpec.describe 'the run state of the Live layer' do
  # The path of the PowerShell script of the Live layer.
  #
  # @return [String] the path
  def script_path
    File.expand_path '../../../assets/live/run.ps1', __dir__
  end

  # Runs an expression against the PowerShell script of the Live layer, with a log.
  #
  # @param log [String] the text of the log
  # @param expression [String] the PowerShell expression to run
  # @return [String] the output of the expression
  def powershell(log, expression)
    file = Tempfile.new(['gui_harness_live_log', '.txt'])
    file.write log
    file.close
    path = GuiHarness::Live::Launcher.windows_path file.path
    script = GuiHarness::Live::Launcher.windows_path script_path
    command = ". '#{script}' -Exe notepad.exe -Set C:/missing.txt -Log '#{path}'; #{expression}"
    output, = Open3.capture2e 'powershell.exe', '-NoProfile', '-Command', command
    output
  ensure
    file&.close
    file&.unlink
  end

  it 'answers the recovery prompt of Live' do
    log = 'info: Message Box: Live unexpectedly quit while you were working on the Live Set ' \
          "'Untitled'. Would you like to recover your work?"

    expression = '$context = New-RunContext -LogStart 0; ' \
                 '$context.ProcessIds = @(); ' \
                 '$state = New-RunState; ' \
                 'Update-RunState $state $context; ' \
                 "'attempt=' + $state.RecoveryAttempt"

    expect(powershell(log, expression).strip).to eq('attempt=1')
  end

  it 'reads the load of the set from the log of Live' do
    log = 'info: Loading command-line document: done.'

    expression = '$context = New-RunContext -LogStart 0; ' \
                 '$state = New-RunState; ' \
                 'Update-RunState $state $context; ' \
                 "'loaded=' + $state.Loaded + ' done=' + $state.Done"

    expect(powershell(log, expression).strip).to eq('loaded=True done=True')
  end

  it 'reports the document that could not be loaded' do
    log = 'info: error: Failed to load command-line document: The document is corrupt.'

    expression = '$context = New-RunContext -LogStart 0; ' \
                 '$state = New-RunState; ' \
                 'Update-RunState $state $context; ' \
                 "'dialog=' + $state.Dialog + ' done=' + $state.Done"

    expect(powershell(log, expression).strip).to eq('dialog=The document is corrupt. done=True')
  end
end
