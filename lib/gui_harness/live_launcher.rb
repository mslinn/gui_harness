# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative 'log'

# Real-GUI compatibility harness.
#
# The Ruby layer is intentionally thin: it launches a native Windows GUI process,
# passes the target file to it, and then interprets whatever visible modal window
# the app exposes. The actual window enumeration and UIAutomation inspection live
# in the PowerShell sidecar so the Ruby API can remain focused on test output and
# structured results.
module GuiHarness
  module LiveLauncher
    VISIBILITY_LEVELS = %i[normal minimized hidden].freeze
    INVISIBLE_VISIBILITY_LEVELS = %i[minimized hidden].freeze

    DIALOG_RULES = [
      {
        action:  nil,
        id:      'updater',
        pattern: /InstallHelper|installing packages/i,
        type:    :updater,
      },
      {
        action:  { type: 'button', value: 'OK' },
        id:      'fatal',
        pattern: /A serious program error has occurred\.|fatal error/i,
        type:    :fatal,
      },
      {
        action:  { type: 'button', value: 'No' },
        id:      'recover',
        pattern: /Would you like to recover your work\?/i,
        type:    :recovery,
      },
      {
        action:  { type: 'button', value: 'No' },
        id:      'save',
        pattern: /Save changes\?/i,
        type:    :save_changes,
      },
      {
        action:  { type: 'button', value: 'OK' },
        id:      'error',
        pattern: /Cannot\s+find\s+the\s+(file|.*\s+file)\.?|Make\s+sure\s+the\s+path\s+and\s+file\s+name\s+are\s+correct|
                  The\s+file\s+is\s+in\s+use|The\s+file\s+does\s+not\s+exist|cannot\s+find\s+the\s+path\s+specified/ix,
        type:    :error,
      },
      {
        action:  { type: 'button', value: 'OK' },
        id:      'shutdown',
        pattern: /Live will shut down after this message box is closed\./i,
        type:    :fatal,
      }
    ].freeze

    SCRIPT = File.read(File.expand_path('../../assets/gui_harness_live_launcher.ps1', __dir__))

    DISMISS_ACTIONS = {
      'button=OK' => { type: 'button', value: 'OK' },
      'button=No' => { type: 'button', value: 'No' },
      'key=n'     => { type: 'key', value: 'n' },
    }.freeze

    Result = Struct.new(:exit_code, :output, :dialog, :dialog_type, :dismiss_action, :log, :loaded, :crashed,
                        :saved, :saved_path, :updater, :messages, keyword_init: true) do
      def success?
        exit_code.to_i.zero? && dialog.nil? && !crashed
      end

      def outcome
        return :loaded if exit_code.to_i.zero? && !crashed && dialog.nil?
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

      def normalize_visibility(visibility)
        candidate = visibility.to_s.strip.downcase.to_sym
        return candidate if VISIBILITY_LEVELS.include?(candidate)

        raise ArgumentError, "visibility must be one of: #{VISIBILITY_LEVELS.join(', ')}"
      end

      def visibility_style(visibility)
        case normalize_visibility(visibility)
        when :hidden then 'Hidden'
        when :minimized then 'Minimized'
        else 'Normal'
        end
      end

      def debug_visibility_message(visibility, executable)
        level = normalize_visibility(visibility)
        "Launching GUI app with visibility=#{level} executable=#{executable}"
      end

      def launch(executable, set, log: nil, timeout: 3, visibility: :normal, save: nil, save_in_place: false,
                 debug: false)
        level = normalize_visibility(visibility)
        Log.debug(debug_visibility_message(level, executable)) if INVISIBLE_VISIBILITY_LEVELS.include?(level)

        script = write_powershell_live_launcher_script
        pid_file = File.join windows_directory, 'gui_harness_live_launcher.pid'
        FileUtils.rm_f pid_file
        args = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', windows_path(script),
                '-Exe', windows_path(executable), '-Set', windows_path(set),
                '-TimeoutSeconds', timeout.to_s, '-Visibility', level.to_s]
        args += ['-Log', windows_path(log)] unless log.nil?
        args += ['-SavePath', windows_path(save)] unless save.nil?
        args << '-SaveInPlace' if save_in_place
        args += ['-PidFile', windows_path(pid_file)]
        args << '-HarnessDebug' if debug

        begin
          output, status = Open3.capture2e(*args)
        ensure
          stop_application pid_file
        end
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
        return path if path.match?(%r{\A[A-Za-z]:[\\/]})
        return path unless path.include?('/') || File.exist?(path)

        absolute = File.expand_path path
        out, status = Open3.capture2e 'wslpath', '-w', absolute
        status.success? ? out.strip : absolute
      end

      private

      # Stops an application that the launcher script left running.
      #
      # The script writes the pid of the application down, and removes the file when the
      # application is stopped. A file that is still there means that the application is still
      # running: the script was cut short, most of the time by an interrupt from the outside.
      # An application that is left running goes on by itself, and it takes the machine over
      # when it checks for package installation.
      #
      # @param pid_file [String] the file the pid is written down in
      # @return [Integer, nil] the pid of the application that was stopped
      def stop_application(pid_file)
        return nil unless File.exist?(pid_file)

        pid = File.read(pid_file).to_s.strip
        File.delete pid_file
        return nil unless pid.match?(/\A\d+\z/)

        Open3.capture2e 'powershell.exe', '-NoProfile', '-Command', stop_tree_command(pid.to_i)
        pid.to_i
      end

      # The command that stops a process and everything it started.
      #
      # @param pid [Integer] the pid of the process
      # @return [String] the command
      def stop_tree_command(pid)
        <<~POWERSHELL.strip
          $ids = @(); $stack = New-Object 'System.Collections.Generic.Stack[int]'; $stack.Push(#{pid});
          while ($stack.Count -gt 0) {
            $current = $stack.Pop();
            if ($ids -contains $current) { continue };
            $ids += $current;
            foreach ($child in Get-CimInstance Win32_Process -Filter "ParentProcessId = $current" -ErrorAction SilentlyContinue) {
              $stack.Push([int]$child.ProcessId)
            }
          };
          foreach ($id in $ids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        POWERSHELL
      end

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

      def parse(output, status)
        clean_output = output.gsub("\r\n", "\n")
        dialog = clean_output[/^DIALOG: (.*)$/, 1]
        dialog = nil if dialog.nil? || dialog.strip == 'none'

        dialog_type = clean_output[/^DIALOG_TYPE: (.*)$/, 1]&.strip
        dialog_type = nil if dialog_type.to_s.casecmp('none').zero?
        dialog_type = dialog_type&.to_sym
        dismiss_action = clean_output[/^DISMISS_ACTION: (.*)$/, 1]
        dismiss_action = DISMISS_ACTIONS[dismiss_action] if dismiss_action

        dialog_info = classify_dialog(dialog)
        dialog_type ||= dialog_info && dialog_info[:type]
        dismiss_action ||= dialog_info && dialog_info[:action]

        crashed = clean_output[/^CRASHED: (.*)$/, 1].to_s.strip == 'yes'
        updater = clean_output[/^UPDATER: (.*)$/, 1].to_s.strip == 'yes'
        messages = clean_output.scan(/^MESSAGE: (.*)$/).flatten
        saved = clean_output[/^SAVED: (.*)$/, 1].to_s.strip == 'yes'
        saved_path = clean_output[/^SAVED_PATH: (.*)$/, 1]
        log = clean_output[/--- LOG ---\s*(.*)\z/m, 1].to_s

        # The set is loaded when Live says that it has loaded the document it was given. Live
        # says so even when the document could not be loaded, so the failure is looked for as
        # well.
        loaded = log.include?('Loading command-line document: done.') &&
                 !log.include?('Failed to load command-line document')

        Result.new(crashed:        crashed,
                   dialog:         dialog,
                   dialog_type:    dialog_type,
                   dismiss_action: dismiss_action,
                   exit_code:      status.exitstatus,
                   loaded:         loaded,
                   log:            log,
                   output:         clean_output,
                   saved:          saved,
                   saved_path:     saved_path,
                   updater:        updater,
                   messages:       messages)
      end
    end
  end
end

LiveLauncher = GuiHarness::LiveLauncher
