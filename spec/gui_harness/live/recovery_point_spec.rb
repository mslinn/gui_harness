# frozen_string_literal: false

require 'spec_helper'
require 'open3'
require 'tmpdir'

# The examples ask the PowerShell script about the recovery point Live leaves behind.
#
# Live writes a recovery point when it is killed, and it holds the point in its Preferences
# folder, next to its log. The point is what drives the recovery prompt of the next launch.
RSpec.describe 'the recovery point of Live' do
  # The path of the PowerShell script of the Live layer.
  #
  # @return [String] the path
  def script_path
    File.expand_path '../../../assets/live/run.ps1', __dir__
  end

  # Runs an expression against the PowerShell script of the Live layer, with a log.
  #
  # @param log [String] the path of the log
  # @param expression [String] the PowerShell expression to run
  # @return [String] the output of the expression
  def powershell(log, expression)
    script = GuiHarness::Live::Launcher.windows_path script_path
    command = ". '#{script}' -Exe notepad.exe -Set C:/missing.txt -Log '#{log}'; #{expression}"
    output, = Open3.capture2e 'powershell.exe', '-NoProfile', '-Command', command
    output
  end

  # The folder that stands in for Live's Preferences folder.
  #
  # @return [String] the path of the folder
  def preferences
    @preferences ||= Dir.mktmpdir 'gui_harness_preferences'
  end

  # The path of the log in the Preferences folder.
  #
  # @return [String] the path of the log
  def log_path
    File.join preferences, 'Log.txt'
  end

  # The path of the recovery point in the Preferences folder.
  #
  # @return [String] the path of the file
  def recovery_path
    File.join preferences, 'CrashRecoveryInfo.cfg'
  end

  before { File.write log_path, '' }

  after { FileUtils.remove_entry preferences }

  it 'is not there when Live was closed' do
    expression = '$context = New-RunContext -LogStart 0; ' \
                 "'point=' + (Get-RecoveryPoint $context)"

    expect(powershell(GuiHarness::Live::Launcher.windows_path(log_path), expression).strip).to eq('point=')
  end

  it 'is there when Live was killed' do
    File.write recovery_path, 'a recovery point'

    expression = '$context = New-RunContext -LogStart 0; ' \
                 "'point=' + (Get-RecoveryPoint $context)"

    expect(powershell(GuiHarness::Live::Launcher.windows_path(log_path), expression).strip)
      .to eq("point=#{GuiHarness::Live::Launcher.windows_path(recovery_path)}")
  end

  it 'is moved into the folder of the ones that were answered' do
    File.write recovery_path, 'a recovery point'
    FileUtils.mkdir_p File.join(preferences, 'BaseFiles')
    File.write File.join(preferences, 'BaseFiles', 'a set.als'), 'a set'

    expression = '$context = New-RunContext -LogStart 0; ' \
                 'Clear-RecoveryPoint $context; ' \
                 "'point=' + (Get-RecoveryPoint $context)"
    powershell(GuiHarness::Live::Launcher.windows_path(log_path), expression)

    expect(File.exist?(recovery_path)).to be false
    expect(File.exist?(File.join(preferences, 'BaseFiles'))).to be false
    expect(Dir.children(File.join(preferences, 'Crash')).sort).to match_array(
      ['CrashRecoveryInfo.cfg', 'BaseFiles'].map { |name| /\A\d{4}_\d{2}_\d{2}__\d{2}_\d{2}_\d{2}_#{name}\z/ }
    )
  end
end
