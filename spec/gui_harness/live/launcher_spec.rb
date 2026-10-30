# frozen_string_literal: false

require 'spec_helper'

# The expressions the examples ask the PowerShell script for.
#
# Every expression is evaluated in the same PowerShell process, because starting one costs
# more than the expression does.
LIVE_EXPRESSIONS = {
  'updater'     => "(Get-DialogInfo 'Live is installing packages').Type",
  'shutdown'    => "(Get-DialogInfo 'Live will shut down after this message box is closed.').Type",
  'recovery'    => "(Get-DialogInfo 'Live unexpectedly quit while you were working on the Live Set').Type",
  'no_helper'   => "@(Get-InstallHelpers -Names 'no_such_process_xyz').Count",
  'update'      => "Get-PendingUpdate '2026-10-29T17:03:31: info: WebConnector: auto-update available: 12.4.7'",
  'update_done' => "Get-PendingUpdate '2026-10-29T17:03:31: info: WebConnector: auto-update available: 12.4.7 " \
                   "2026-10-30T09:00:00: info: Init: Version: ''Live 12.4.7 Build: 2026-09-10_0de5c8fa9a'''",
  'no_update'   => "Get-PendingUpdate '2026-10-29T17:03:31: info: Live App: Check for package installation'",
}.freeze

RSpec.describe GuiHarness::Live::Launcher do
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
    script = described_class.windows_path script_path
    command = 'powershell.exe -NoProfile -Command ' \
              "\". '#{script}' -Exe notepad.exe -Set C:/missing.txt; #{expression}\" 2>&1"
    `#{command}`
  end

  describe '.classify_dialog' do
    it 'recognizes the dialogs of Live' do
      expect(described_class.classify_dialog('Live is installing packages')).to eq(
        { type: :updater, action: nil }
      )

      expect(described_class.classify_dialog('Live will shut down after this message box is closed.')).to eq(
        { type: :fatal, action: { type: 'button', value: 'OK' } }
      )

      msg = "Live unexpectedly quit while you were working on the Live Set 'Untitled'. Would you like to recover your work?"
      expect(described_class.classify_dialog(msg)).to eq(
        { type: :recovery, action: { type: 'button', value: 'No' } }
      )
    end

    it 'recognizes the dialogs that every program has' do
      expect(described_class.classify_dialog('Save changes?')).to eq(
        { type: :save_changes, action: { type: 'button', value: 'No' } }
      )

      expect(described_class.classify_dialog('Some unexpected Live window')).to eq(
        { type: :unknown, action: nil }
      )
    end
  end

  describe '.command' do
    it 'hands the rungs of the ladder of the Live layer to the sidecar' do
      args = described_class.command 'notepad.exe', 'C:/missing.txt'

      expect(args).to include('-ShutdownRungs')
      expect(args[args.index('-ShutdownRungs') + 1]).to eq(described_class.shutdown_rungs.join(','))
      expect(described_class.shutdown_rungs).to eq(GuiHarness::Live::Shutdown::RUNGS)
    end
  end

  describe 'the PowerShell script' do
    # The values the expressions have.
    #
    # @return [Hash] the values, by the name of the expression
    def self.values
      @values ||= begin
        script = described_class.windows_path File.expand_path('../../../assets/live/run.ps1', __dir__)
        body = LIVE_EXPRESSIONS.map do |name, expression|
          "Write-Output ('#{name}=' + (#{expression}))"
        end.join('; ')
        command = 'powershell.exe -NoProfile -Command ' \
                  "\". '#{script}' -Exe notepad.exe -Set C:/missing.txt; #{body}\" 2>&1"
        `#{command}`.lines.to_h { |line| line.chomp.split('=', 2) }
      end
    end

    it 'classifies the dialogs of Live' do
      expect(self.class.values['updater']).to eq('updater')
      expect(self.class.values['shutdown']).to eq('fatal')
      expect(self.class.values['recovery']).to eq('recovery')
    end

    it 'finds the installer helper of Ableton by its process name' do
      expect(self.class.values['no_helper']).to eq('0')
    end

    it 'finds a process that is running' do
      system 'powershell.exe', '-NoProfile', '-Command', 'Start-Process notepad.exe'
      sleep 1

      expect(powershell("@(Get-InstallHelpers -Names 'notepad').Count").strip.to_i).to be >= 1
    ensure
      system 'powershell.exe', '-NoProfile', '-Command', 'Stop-Process -Name notepad -Force -ErrorAction SilentlyContinue'
    end

    it 'tells an update that is waiting from one that has been installed' do
      expect(self.class.values['update']).to eq('12.4.7')
      expect(self.class.values['update_done']).to eq('')
      expect(self.class.values['no_update']).to eq('')
    end
  end

  describe '.parse' do
    it 'reports a run in which the set was loaded as loaded' do
      output = <<~TEXT
        DIALOG: none
        CRASHED: no
        --- LOG ---
        Begin ExchangeDocument
        End ExchangeDocument
        Loading command-line document: done.
      TEXT

      status = Struct.new(:exitstatus, keyword_init: true).new(exitstatus: 0)
      result = described_class.send(:parse, output, status)

      expect(result.loaded).to be true
      expect(result.outcome).to eq(:loaded)
    end

    it 'reports a run in which nothing was loaded as unknown' do
      # Live quits at once when it is handed a file that does not exist, and it logs nothing
      # about the failure, so there is no dialog to report and the outcome says the run came
      # to nothing.
      output = <<~TEXT
        DIALOG: none
        CRASHED: no
        --- LOG ---
      TEXT

      status = Struct.new(:exitstatus, keyword_init: true).new(exitstatus: 0)
      result = described_class.send(:parse, output, status)

      expect(result.loaded).to be false
      expect(result.outcome).to eq(:unknown)
    end

    it 'reports a run that was blocked by the installer of Ableton' do
      output = <<~TEXT
        DIALOG: Live is installing packages: the installer takes over the machine and Live waits for it
        DIALOG_TYPE: updater
        DISMISS_ACTION: none
        CRASHED: no
        UPDATER: yes
        --- LOG ---
        Live App: Check for package installation
      TEXT

      status = Struct.new(:exitstatus, keyword_init: true).new(exitstatus: 0)
      result = described_class.send(:parse, output, status)

      expect(result.updater).to be true
      expect(result.dialog_type).to eq(:updater)
      expect(result.outcome).to eq(:blocked)
    end

    it 'tells the user that an update will be installed' do
      output = <<~TEXT
        DIALOG: none
        CRASHED: no
        UPDATER: no
        EXITED_CLEANLY: yes
        PENDING_UPDATE: 12.4.7
        --- LOG ---
        Init: Version: 'Live 12.4.6 Build: 2026-09-10_0de5c8fa9a'
        WebConnector: auto-update available: 12.4.7
      TEXT

      status = Struct.new(:exitstatus, keyword_init: true).new(exitstatus: 0)
      result = described_class.send(:parse, output, status)

      expect(result.exited_cleanly).to be true
      expect(result.messages).to eq(['Live 12.4.6 will install update 12.4.7 automatically when it exits.'])
    end

    it 'says nothing about an update when there is none' do
      output = <<~TEXT
        DIALOG: none
        CRASHED: no
        UPDATER: no
        EXITED_CLEANLY: no
        --- LOG ---
        Init: Version: 'Live 12.4.6 Build: 2026-09-10_0de5c8fa9a'
      TEXT

      status = Struct.new(:exitstatus, keyword_init: true).new(exitstatus: 0)
      result = described_class.send(:parse, output, status)

      expect(result.exited_cleanly).to be false
      expect(result.messages).to be_empty
    end
  end
end
