# frozen_string_literal: true

require 'open3'
require 'tmpdir'

# Real-GUI compatibility harness.
#
# The Ruby layer is intentionally thin: it launches a native Windows GUI process,
# passes the target file to it, and then interprets whatever visible modal window
# the app exposes. The actual window enumeration and UIAutomation inspection live
# in the PowerShell sidecar so the Ruby API can remain focused on test output and
# structured results.
module GuiHarness
  module LiveLauncher
    DIALOG_RULES = [
      {
        action: { type: 'button', value: 'OK' },
        id: 'fatal',
        pattern: /A serious program error has occurred\.|fatal error/i,
        type: :fatal,
      },
      {
        action: { type: 'button', value: 'No' },
        id: 'recover',
        pattern: /Would you like to recover your work\?/i,
        type: :recovery,
      },
      {
        action: { type: 'button', value: 'No' },
        id: 'save',
        pattern: /Save changes\?/i,
        type: :save_changes,
      },
      {
        action: { type: 'button', value: 'OK' },
        id: 'error',
        pattern: /Cannot find the file|Make sure the path and file name are correct|The file is in use|The file does not exist/i,
        type: :error,
      },
      {
        action: { type: 'button', value: 'OK' },
        id: 'shutdown',
        pattern: /Live will shut down after this message box is closed\./i,
        type: :fatal,
      }
    ].freeze

    SCRIPT = File.read(File.expand_path('live_launcher.ps1', __dir__))

    Result = Struct.new(:exit_code, :output, :dialog, :dialog_type, :dismiss_action, :log, :loaded, :crashed, keyword_init: true) do
      def success?
        exit_code.zero? && dialog.nil? && loaded
      end

      def outcome
        return :loaded if loaded && !crashed && dialog.nil?
        return :crashed if crashed || dialog_type == :fatal
        return :unknown if dialog_type == :unknown
        return :blocked if dialog_type && dialog_type != :fatal

        :unknown
      end
    end

    class << self
      def classify_dialog(text)
        return nil if text.nil? || text.strip.empty?

        rule = DIALOG_RULES.find { |candidate| text.match?(candidate[:pattern]) }
        return { type: :unknown, action: nil } if rule.nil?

        { type: rule[:type], action: rule[:action].dup }
      end

      def launch(executable, set, log: nil, timeout: 3)
        script = write_powershell_live_launcher_script
        args = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', windows_path(script),
                '-Exe', windows_path(executable), '-Set', windows_path(set),
                '-TimeoutSeconds', timeout.to_s]
        args += ['-Log', windows_path(log)] unless log.nil?

        output, status = Open3.capture2e(*args)
        parse output, status
      end

      def available?(executable)
        return false if executable.nil?
        return false unless File.exist?(executable)

        _, status = Open3.capture2e 'powershell.exe', '-NoProfile', '-Command', 'exit 0'
        status.success?
      rescue Errno::ENOENT
        false
      end

      def windows_path(path)
        return path unless path.start_with?('/');

        out, status = Open3.capture2e 'wslpath', '-w', path
        status.success? ? out.strip : path
      end

      private

      def write_powershell_live_launcher_script
        path = File.join windows_directory, 'gui_harness_live_launcher.ps1'
        File.write path, SCRIPT
        path
      end

      def windows_directory
        @windows_directory ||= begin
          dir = ENV['TEMP'] || ENV['TMP'] || 'C:\Windows\Temp'
          wsl = windows_path dir
          wsl.start_with?('/mnt/') ? wsl : '/mnt/c/Windows/Temp'
        end
      end

      DISMISS_ACTIONS = {
        'button=OK' => { type: 'button', value: 'OK' },
        'button=No' => { type: 'button', value: 'No' },
        'key=n' => { type: 'key', value: 'n' },
      }.freeze

      def parse(output, status)
        clean_output = output.gsub("\r\n", "\n")
        dialog = clean_output[/^DIALOG: (.*)$/, 1]
        dialog = nil if dialog.nil? || dialog.strip == 'none'

        dialog_type = clean_output[/^DIALOG_TYPE: (.*)$/, 1]&.strip&.to_sym
        dismiss_action = clean_output[/^DISMISS_ACTION: (.*)$/, 1]
        dismiss_action = DISMISS_ACTIONS[dismiss_action] if dismiss_action

        dialog_info = classify_dialog(dialog)
        dialog_type ||= dialog_info && dialog_info[:type]
        dismiss_action ||= dialog_info && dialog_info[:action]

        crashed = clean_output[/^CRASHED: (.*)$/, 1].to_s.strip == 'yes'
        log = clean_output[/--- LOG ---\s*(.*)\z/m, 1].to_s
        loaded = log.include?('End ExchangeDocument')

        Result.new(crashed: crashed,
                   dialog: dialog,
                   dialog_type: dialog_type,
                   dismiss_action: dismiss_action,
                   exit_code: status.exitstatus,
                   loaded: loaded,
                   log: log,
                   output: clean_output)
      end
    end
  end
end

LiveLauncher = GuiHarness::LiveLauncher
