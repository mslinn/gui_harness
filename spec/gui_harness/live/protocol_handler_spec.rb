# frozen_string_literal: false

require 'spec_helper'
require 'open3'
require 'securerandom'

# The examples ask the PowerShell script of the Live layer about the registration of the
# `ableton:` protocol.
#
# Live rewrites the machine-wide registration of the protocol when it starts and finds that
# the registration names another version of Live. That key is machine-wide, so the rewrite is
# elevated, and the elevation is the prompt of UAC.
#
# The shell resolves a registration from the per-user hive first, so the Live layer points
# the per-user registration at the version it is about to run, and the prompt does not come.
# The per-user registration of the run is taken away when the run is over, and the
# registration of the machine applies again.
RSpec.describe 'the registration of the protocol of Live' do
  # The path of the PowerShell script of the Live layer.
  #
  # @return [String] the path
  def script_path
    File.expand_path '../../../assets/live/run.ps1', __dir__
  end

  # The key the examples write the registration to.
  #
  # The key of the Live layer is a key of the machine the examples run on, so the examples
  # use a key of their own and leave the registration of the machine alone.
  #
  # @return [String] the path of the key
  def handler_key
    @handler_key ||= "HKCU:\\Software\\GuiHarnessSpec\\#{SecureRandom.hex(4)}"
  end

  # The path of a copy of Live that is installed.
  #
  # @return [String] the path
  def live_executable
    @live_executable ||= windows_path 'C:\ProgramData\Ableton\Live 11 Suite\Program\Ableton Live 11 Suite.exe'
  end

  # The path of a path of Windows, as it is written to the sidecar.
  #
  # @param path [String] the path
  # @return [String] the path
  def windows_path(path)
    GuiHarness::Live::Launcher.windows_path path
  end

  # Runs an expression against the PowerShell script of the Live layer.
  #
  # @param expression [String] the PowerShell expression to run
  # @return [String] the output of the expression
  def powershell(expression)
    script = GuiHarness::Live::Launcher.windows_path script_path
    command = ". '#{script}' -Exe notepad.exe -Set C:/missing.txt; " \
              "function Get-ProtocolHandlerKey { return '#{handler_key}' }; " \
              "#{expression}"
    output, = Open3.capture2e 'powershell.exe', '-NoProfile', '-Command', command
    output
  end

  # The value of the registration, as it is in the key of the examples.
  #
  # @return [String] the value
  def registration
    powershell("$key = Get-Item -LiteralPath '#{handler_key}' -ErrorAction SilentlyContinue; " \
               'if ($key) { $key.GetValue("") } else { "" }').strip
  end

  # The value of the registration of the machine, as the shell resolves it.
  #
  # @return [String] the value
  def effective_registration
    powershell('Get-EffectiveProtocolHandler').strip
  end

  # The value of the registration of the machine, as it is in the machine-wide key.
  #
  # @return [String] the value
  def machine_registration
    powershell("(Get-Item 'HKLM:\\SOFTWARE\\Classes\\ableton\\Shell\\open\\command').GetValue('')").strip
  end

  # The executable that a registration names.
  #
  # Live writes its own registration without quotes around the path of the executable, and
  # the Live layer writes it with them, so the examples compare the executable and not the
  # whole value.
  #
  # @param value [String] the value of a registration
  # @return [String] the path of the executable
  def executable_of(value)
    match = value.to_s.match(/\A"?(.+?\.exe)"?/)
    match && match[1]
  end

  # The expression that makes a run of the given executable, and that says what the run did
  # to the registration.
  #
  # @param expression [String] the expression of the run
  # @param exe [String] the path of the executable the run wants
  # @return [String] the output of the expression
  def run(expression, exe = live_executable)
    powershell('$context = New-RunContext -LogStart 0; ' \
               "$context.Exe = '#{exe}'; " + expression)
  end

  after do
    powershell "Remove-Item -LiteralPath '#{handler_key}' -Recurse -Force -ErrorAction SilentlyContinue"
  end

  it 'names the version that is about to be run' do
    expression = "'written=' + (Set-ApplicationRegistration $context); " \
                 "'touched=' + $context.RegistrationWritten"

    expect(run(expression).split("\n").map(&:strip)).to eq(['written=True', 'touched=True'])
    expect(executable_of(registration)).to eq(live_executable)
  end

  it 'is not written when it already names that version' do
    powershell "New-Item -Path '#{handler_key}' -Force | Out-Null; " \
               "Set-Item -Path '#{handler_key}' -Value '\"#{live_executable}\" \"%1\"'"

    expression = "'written=' + (Set-ApplicationRegistration $context); " \
                 "'touched=' + $context.RegistrationWritten"

    expect(run(expression).split("\n").map(&:strip)).to eq(['written=False', 'touched=False'])
    expect(executable_of(registration)).to eq(live_executable)
  end

  it 'does nothing when the default names the version that is wanted' do
    expression = "'written=' + (Set-ApplicationRegistration $context); " \
                 "'touched=' + $context.RegistrationWritten"

    default_exe = executable_of(machine_registration)
    expect(default_exe).not_to be_empty

    expect(run(expression, default_exe).split("\n").map(&:strip)).to eq(['written=False', 'touched=False'])
    expect(registration).to eq('')
  end

  it 'shadows the registration of the machine' do
    powershell "New-Item -Path '#{handler_key}' -Force | Out-Null; " \
               "Set-Item -Path '#{handler_key}' -Value '\"#{live_executable}\" \"%1\"'"

    expect(executable_of(effective_registration)).to eq(live_executable)
  end

  it 'is taken away when the run is over' do
    expression = 'Set-ApplicationRegistration $context | Out-Null; ' \
                 "'removed=' + (Restore-ApplicationRegistration $context)"

    expect(run(expression).strip).to eq('removed=True')
    expect(registration).to eq('')
    expect(effective_registration).to eq(machine_registration)
  end

  it 'is left alone when the run wrote nothing' do
    powershell "New-Item -Path '#{handler_key}' -Force | Out-Null; " \
               "Set-Item -Path '#{handler_key}' -Value '\"#{live_executable}\" \"%1\"'"

    expression = "'removed=' + (Restore-ApplicationRegistration $context)"

    expect(run(expression).strip).to eq('removed=False')
    expect(executable_of(registration)).to eq(live_executable)
  end
end
