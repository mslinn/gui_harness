# frozen_string_literal: false

require 'spec_helper'
require 'tempfile'

# The expressions the examples ask the PowerShell script for.
#
# Every expression is evaluated in the same PowerShell process, because starting one costs
# more than the expression does.
GENERIC_EXPRESSIONS = {
  'key_n'        => "Get-KeyCode 'n'",
  'key_esc'      => "Get-KeyCode 'esc'",
  'key_enter'    => "Get-KeyCode 'enter'",
  'key_f1'       => "Get-KeyCode 'f1'",
  'escaped'      => "Escape-Keys 'C:/a+b (x)'",
  'fatal'        => "(Get-DialogInfo 'A serious program error has occurred.').Type",
  'recovery'     => "(Get-DialogInfo 'Would you like to recover your work?').Type",
  'save_changes' => "(Get-DialogInfo 'Save changes?').Type",
  'error'        => "(Get-DialogInfo 'The system cannot find the path specified.').Type",
  'unknown'      => "(Get-DialogInfo 'Some unexpected window').Type",
  'save_action'  => "(Get-DialogInfo 'Save changes?').Action",
  'error_action' => "(Get-DialogInfo 'The system cannot find the path specified.').Action",
}.freeze

RSpec.describe GuiHarness::Generic::Launcher do
  # The number of Notepad processes Windows is running.
  #
  # @return [Integer] the number of them
  def notepad_process_count
    command = 'powershell.exe -NoProfile -Command "Get-Process -Name notepad ' \
              '-ErrorAction SilentlyContinue | Measure-Object | ' \
              'Select-Object -ExpandProperty Count"'
    `#{command}`.strip.to_i
  end

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
    script = described_class.windows_path script_path
    command = 'powershell.exe -NoProfile -Command ' \
              "\". '#{script}' -Exe notepad.exe -Set C:/missing.txt; #{expression}\" 2>&1"
    `#{command}`
  end

  describe '.classify_dialog' do
    it 'recognizes each supported dialog family and the required dismissal action' do
      expect(described_class.classify_dialog('A serious program error has occurred.')).to eq(
        { type: :fatal, action: { type: 'button', value: 'OK' } }
      )

      expect(described_class.classify_dialog('Would you like to recover your work?')).to eq(
        { type: :recovery, action: { type: 'button', value: 'No' } }
      )

      expect(described_class.classify_dialog('Save changes?')).to eq(
        { type: :save_changes, action: { type: 'button', value: 'No' } }
      )

      notepad_error = "Cannot find the file 'C:/missing.txt'. Make sure the path and file name are correct."
      expect(described_class.classify_dialog(notepad_error)).to eq(
        { type: :error, action: { type: 'button', value: 'OK' } }
      )

      expect(described_class.classify_dialog('Some unexpected window')).to eq(
        { type: :unknown, action: nil }
      )
    end

    it 'knows nothing of the dialogs of Live' do
      expect(described_class.classify_dialog('Live is installing packages')).to eq(
        { type: :unknown, action: nil }
      )
    end
  end

  describe '.visibility_levels' do
    [%i[normal success], %i[normal failure], %i[minimized success], %i[minimized failure], %i[hidden success],
     %i[hidden failure]].each do |visibility, status|
      it "classifies #{status} correctly when visibility=#{visibility}" do
        output = if status == :success
                   <<~TEXT
                     DIALOG: none
                     DIALOG_TYPE: none
                     DISMISS_ACTION: none
                     CRASHED: no
                     --- LOG ---
                     Loading document "C:/demo.als"
                     Begin ExchangeDocument
                     End ExchangeDocument
                     Loading command-line document: done.
                   TEXT
                 else
                   <<~TEXT
                     DIALOG: Cannot find the file 'C:/missing.txt'. Make sure the path and file name are correct.
                     DIALOG_TYPE: error
                     DISMISS_ACTION: button=OK
                     CRASHED: no
                     --- LOG ---
                     Loading document "C:/demo.als"
                     Begin ExchangeDocument
                     Error: file not found
                   TEXT
                 end

        status_obj = Struct.new(:exitstatus, keyword_init: true).new(exitstatus: 0)
        result = described_class.send(:parse, output, status_obj)

        if status == :success
          expect(result.success?).to be(true)
          expect(result.dialog).to be_nil
          expect(result.dialog_type).to be_nil
          expect(result.outcome).to eq(:loaded)
        else
          expect(result.success?).to be(false)
          expect(result.dialog).to include('Cannot find the file')
          expect(result.dialog_type).to eq(:error)
          expect(result.dismiss_action).to eq({ type: 'button', value: 'OK' })
          expect(result.outcome).to eq(:blocked)
        end

        if %i[minimized hidden].include?(visibility)
          message = described_class.debug_visibility_message(visibility, 'notepad.exe')
          expect(message).to include("visibility=#{visibility}")
          expect(message).to include('notepad.exe')
        end
      end
    end
  end

  describe '.command' do
    it 'hands the rungs of the ladder of the layer to the sidecar' do
      args = described_class.command 'notepad.exe', 'C:/missing.txt'

      expect(args).to include('-ShutdownRungs')
      expect(args[args.index('-ShutdownRungs') + 1]).to eq(described_class.shutdown_rungs.join(','))
      expect(described_class.shutdown_rungs).to eq(GuiHarness::Generic::Shutdown::RUNGS)
    end
  end

  describe '.launch' do
    it 'opens Notepad from WSL with a missing file and surfaces the real Windows error dialog quickly' do
      missing_path = 'C:/path/that/does/not/exist/notepad-demo.txt'
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = described_class.launch('notepad.exe', missing_path, timeout: 3)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 6
      expect(result.exit_code).to eq(0)
      expect(result.crashed).to be(false)
      expect(result.outcome).to(satisfy { |outcome| %i[loaded unknown blocked].include?(outcome) })
      if result.dialog
        expect(result.dialog).to match(/cannot find the path specified/i)
        expect(result.dialog_type).to eq(:error)
        expect(result.dismiss_action).to eq({ type: 'button', value: 'OK' })
      end

      expect(notepad_process_count).to eq(0) if Gem.win_platform?
    end

    it 'opens Notepad without an error dialog, reports success, and closes cleanly' do
      file = Tempfile.new(['notepad_ok', '.txt'])
      file.write("hello from gui_harness\n")
      file.flush

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = described_class.launch('notepad.exe', file.path, timeout: 3)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 6
      expect(result.exit_code).to eq(0)
      expect(result.dialog).to be_nil
      expect(result.dialog_type).to be_nil
      expect(result.crashed).to be(false)
      expect(result.outcome).to eq(:loaded)
      expect(result.success?).to be(true)
      expect(result.exited_cleanly).to be(true)

      expect(notepad_process_count).to eq(0) if Gem.win_platform?
    ensure
      file&.close
      file&.unlink
    end
  end

  describe 'the PowerShell script' do
    # The values the expressions have.
    #
    # @return [Hash] the values, by the name of the expression
    def self.values
      @values ||= begin
        script = described_class.windows_path File.expand_path('../../../assets/generic/run.ps1', __dir__)
        body = GENERIC_EXPRESSIONS.map do |name, expression|
          "Write-Output ('#{name}=' + (#{expression}))"
        end.join('; ')
        command = 'powershell.exe -NoProfile -Command ' \
                  "\". '#{script}' -Exe notepad.exe -Set C:/missing.txt; #{body}\" 2>&1"
        `#{command}`.lines.to_h { |line| line.chomp.split('=', 2) }
      end
    end

    it 'maps the keys the harness sends to their virtual key codes' do
      expect(self.class.values['key_n']).to eq('78')
      expect(self.class.values['key_esc']).to eq('27')
      expect(self.class.values['key_enter']).to eq('13')
      expect(self.class.values['key_f1']).to eq('0')
    end

    it 'escapes the characters that SendKeys treats as commands' do
      expect(self.class.values['escaped']).to eq('C:/a{+}b {(}x{)}')
    end

    it 'classifies the dialogs it reads' do
      expect(self.class.values['fatal']).to eq('fatal')
      expect(self.class.values['recovery']).to eq('recovery')
      expect(self.class.values['save_changes']).to eq('save_changes')
      expect(self.class.values['error']).to eq('error')
      expect(self.class.values['unknown']).to eq('unknown')
    end

    it 'names the button that dismisses a dialog' do
      expect(self.class.values['save_action']).to eq('No')
      expect(self.class.values['error_action']).to eq('OK')
    end
  end

  describe '.parse' do
    it 'reads the launch result from launcher output' do
      output = <<~TEXT
        DIALOG: none
        CRASHED: no
        --- LOG ---
        Loading document "C:/demo.als"
        Begin ExchangeDocument
        End ExchangeDocument
        Loading command-line document: done.
      TEXT

      status = Struct.new(:exitstatus, keyword_init: true).new(exitstatus: 0)
      result = described_class.send(:parse, output, status)

      expect(result.exit_code).to eq(0)
      expect(result.dialog).to be_nil
      expect(result.dialog_type).to be_nil
      expect(result.dismiss_action).to be_nil
      expect(result.outcome).to eq(:loaded)
      expect(result.crashed).to be false
      expect(result.loaded).to be true
      expect(result.log).to include('End ExchangeDocument')
    end

    it 'reports a document that could not be loaded as not loaded' do
      output = <<~TEXT
        DIALOG: The document "C:/missing.als" is corrupt and cannot be loaded.
        DIALOG_TYPE: unknown
        DISMISS_ACTION: none
        CRASHED: no
        --- LOG ---
        Begin ExchangeDocument
        End ExchangeDocument
        error: Failed to load command-line document: The document "C:/missing.als" is corrupt and cannot be loaded.
        Loading command-line document: done.
      TEXT

      status = Struct.new(:exitstatus, keyword_init: true).new(exitstatus: 0)
      result = described_class.send(:parse, output, status)

      expect(result.loaded).to be false
      expect(result.outcome).to eq(:unknown)
      expect(result.dialog).to include('cannot be loaded')
    end

    it 'detects a fatal crash from the launcher output' do
      output = <<~TEXT
        DIALOG: A serious program error has occurred.
        DIALOG_TYPE: fatal
        DISMISS_ACTION: button=OK
        CRASHED: yes
        --- LOG ---
        Begin ExchangeDocument
        Exception: Fatal Error
      TEXT
      status = Struct.new(:exitstatus, keyword_init: true).new(exitstatus: 1)
      result = described_class.send(:parse, output, status)

      expect(result.dialog).to eq('A serious program error has occurred.')
      expect(result.dialog_type).to eq(:fatal)
      expect(result.dismiss_action).to eq({ type: 'button', value: 'OK' })
      expect(result.outcome).to eq(:crashed)
      expect(result.crashed).to be true
      expect(result.loaded).to be false
    end

    it 'reports a run in which nothing blocked the application' do
      output = <<~TEXT
        DIALOG: none
        CRASHED: no
        UPDATER: no
        --- LOG ---
        End ExchangeDocument
      TEXT

      status = Struct.new(:exitstatus, keyword_init: true).new(exitstatus: 0)
      result = described_class.send(:parse, output, status)

      expect(result.updater).to be false
      expect(result.outcome).to eq(:loaded)
    end
  end
end
