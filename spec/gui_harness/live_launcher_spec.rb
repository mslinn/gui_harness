# frozen_string_literal: false

require 'spec_helper'
require 'stringio'
require 'tempfile'

RSpec.describe GuiHarness::LiveLauncher do
  # The number of Notepad processes Windows is running.
  #
  # @return [Integer] the number of them
  def notepad_process_count
    command = 'powershell.exe -NoProfile -Command "Get-Process -Name notepad ' \
              '-ErrorAction SilentlyContinue | Measure-Object | ' \
              'Select-Object -ExpandProperty Count"'
    `#{command}`.strip.to_i
  end

  describe '.classify_dialog' do
    it 'recognizes each supported dialog family and the required dismissal action' do
      expect(described_class.classify_dialog('A serious program error has occurred.')).to eq(
        { type: :fatal, action: { type: 'button', value: 'OK' } }
      )

      msg = "Live unexpectedly quit while you were working on the Live Set 'Untitled'. Would you like to recover your work?"
      expect(described_class.classify_dialog(msg)).to eq(
        { type: :recovery, action: { type: 'button', value: 'No' } }
      )

      expect(described_class.classify_dialog('Save changes?')).to eq(
        { type: :save_changes, action: { type: 'button', value: 'No' } }
      )

      notepad_error = "Cannot find the file 'C:/missing.txt'. Make sure the path and file name are correct."
      expect(described_class.classify_dialog(notepad_error)).to eq(
        { type: :error, action: { type: 'button', value: 'OK' } }
      )

      expect(described_class.classify_dialog('Some unexpected Live window')).to eq(
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

      expect(notepad_process_count).to eq(0) if Gem.win_platform?
    ensure
      file&.close
      file&.unlink
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
  end
end
