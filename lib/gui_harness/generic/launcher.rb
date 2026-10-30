# frozen_string_literal: true

require 'fileutils'
require 'open3'
require_relative '../log'
require_relative 'dialog'
require_relative 'result'
require_relative 'shutdown'
require_relative 'windows'

module GuiHarness
  module Generic
    # Drives any GUI program on Windows.
    #
    # The Ruby layer is intentionally thin: it launches a native Windows GUI process, passes
    # the target file to it, and then interprets whatever visible modal window the app
    # exposes. The actual window enumeration and UIAutomation inspection live in the
    # PowerShell sidecar so the Ruby API can remain focused on test output and structured
    # results.
    class Launcher
      extend Windows

      VISIBILITY_LEVELS = %i[normal minimized hidden].freeze
      INVISIBLE_VISIBILITY_LEVELS = %i[minimized hidden].freeze

      DISMISS_ACTIONS = {
        'button=OK' => { type: 'button', value: 'OK' },
        'button=No' => { type: 'button', value: 'No' },
        'key=n'     => { type: 'key', value: 'n' },
      }.freeze

      # The result of a run.
      Result = Generic::Result

      class << self
        # The family of a dialog, and the action that answers it.
        #
        # @param text [String, nil] the text the user sees
        # @return [Hash, nil] the family and the action, or nil when there is no text
        def classify_dialog(text)
          Dialog.classify text
        end

        # The rungs the shutdown ladder of this layer is climbed by.
        #
        # @return [Array] the rungs, in the order they are climbed
        def shutdown_rungs
          Shutdown::RUNGS
        end

        # The assets of this layer, by the path they are written to.
        #
        # The layout of the assets is kept, so that a library can find the library it
        # dot-sources.
        #
        # @return [Hash] the source of each asset, by its path
        def assets
          {
            'generic/gui_harness_generic.ps1' => asset('generic/gui_harness_generic.ps1'),
            'generic/run.ps1'                 => asset('generic/run.ps1'),
          }
        end

        # The script the run is started with.
        #
        # @return [String] the path of the script, relative to the sidecar
        def entry_point
          'generic/run.ps1'
        end

        # Launches a GUI program and reports what it did.
        #
        # @param executable [String] the path of the program
        # @param set [String] the path of the file the program is given
        # @param log [String, nil] the path of the log of the program
        # @param timeout [Integer] how long the program is watched, in seconds
        # @param visibility [Symbol] :normal, :minimized or :hidden
        # @param save [String, nil] the path the file is saved to
        # @param save_in_place [Boolean] whether the file is saved where it is
        # @param debug [Boolean] whether the run is traced
        # @return [Result] what the run did
        def launch(executable, set, log: nil, timeout: 3, visibility: :normal, save: nil, save_in_place: false,
                   debug: false)
          level = normalize_visibility(visibility)
          Log.debug(debug_visibility_message(level, executable)) if INVISIBLE_VISIBILITY_LEVELS.include?(level)

          write_sidecar
          pid_file = pid_file_path
          FileUtils.rm_f pid_file

          args = command(executable, set, log: log, timeout: timeout, visibility: level, save: save,
                                   save_in_place: save_in_place, debug: debug)
          begin
            output, status = Open3.capture2e(*args)
          ensure
            stop_application pid_file
          end
          parse output, status
        end

        # The command that runs the sidecar.
        #
        # The rungs of the shutdown ladder of this layer are handed to the sidecar, and the
        # sidecar climbs exactly those.
        #
        # @param executable [String] the path of the program
        # @param set [String] the path of the file the program is given
        # @param log [String, nil] the path of the log of the program
        # @param timeout [Integer] how long the program is watched, in seconds
        # @param visibility [Symbol] :normal, :minimized or :hidden
        # @param save [String, nil] the path the file is saved to
        # @param save_in_place [Boolean] whether the file is saved where it is
        # @param debug [Boolean] whether the run is traced
        # @return [Array] the command and its arguments
        def command(executable, set, log: nil, timeout: 3, visibility: :normal, save: nil, save_in_place: false,
                    debug: false)
          level = normalize_visibility(visibility)
          args = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', windows_path(entry_point_path),
                  '-Exe', windows_path(executable), '-Set', windows_path(set),
                  '-TimeoutSeconds', timeout.to_s, '-Visibility', level.to_s,
                  '-ShutdownRungs', shutdown_rungs.join(',')]
          args += ['-Log', windows_path(log)] unless log.nil?
          args += ['-SavePath', windows_path(save)] unless save.nil?
          args << '-SaveInPlace' if save_in_place
          args += ['-PidFile', windows_path(pid_file_path)]
          args << '-HarnessDebug' if debug
          args
        end

        # The visibility, as the sidecar names it.
        #
        # @param visibility [Symbol] :normal, :minimized or :hidden
        # @return [String] the name of the visibility
        def visibility_style(visibility)
          case normalize_visibility(visibility)
          when :hidden then 'Hidden'
          when :minimized then 'Minimized'
          else 'Normal'
          end
        end

        # The message that says what the launch is doing.
        #
        # @param visibility [Symbol] the visibility of the window
        # @param executable [String] the path of the program
        # @return [String] the message
        def debug_visibility_message(visibility, executable)
          level = normalize_visibility(visibility)
          "Launching GUI app with visibility=#{level} executable=#{executable}"
        end

        # The visibility that was asked for.
        #
        # @param visibility [Symbol] :normal, :minimized or :hidden
        # @return [Symbol] the visibility
        def normalize_visibility(visibility)
          candidate = visibility.to_s.strip.downcase.to_sym
          return candidate if VISIBILITY_LEVELS.include?(candidate)

          raise ArgumentError, "visibility must be one of: #{VISIBILITY_LEVELS.join(', ')}"
        end

        private

        # The path of an asset of this layer.
        #
        # @param relative [String] the path of the asset, relative to the assets directory
        # @return [String] the path of the asset
        def asset(relative)
          File.expand_path "../../../assets/#{relative}", __dir__
        end

        # Writes the assets of this layer down, so that the sidecar can be run.
        #
        # @return [String] the path of the entry point of the sidecar
        def write_sidecar
          assets.each do |relative, source|
            path = File.join sidecar_root, relative
            FileUtils.mkdir_p File.dirname(path)
            File.write path, File.read(source)
          end
          entry_point_path
        end

        # The directory the sidecar is written to.
        #
        # @return [String] the path of the directory
        def sidecar_root
          File.join windows_directory, 'gui_harness'
        end

        # The path of the entry point of the sidecar.
        #
        # @return [String] the path of the script
        def entry_point_path
          File.join sidecar_root, entry_point
        end

        # The path of the file the pid of the application is written down in.
        #
        # @return [String] the path of the file
        def pid_file_path
          File.join windows_directory, 'gui_harness_launcher.pid'
        end

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

        # The result of a run, as the launcher wrote it down.
        #
        # @param output [String] the output of the launcher
        # @param status [Object] the status of the launcher
        # @return [Result] the result of the run
        def parse(output, status)
          clean_output = output.gsub("\r\n", "\n")
          fields = output_fields(clean_output)

          Result.new(exit_code: status.exitstatus, **fields)
        end

        # The fields of the result, as the launcher wrote them down.
        #
        # @param output [String] the output of the launcher
        # @return [Hash] the fields, by name
        def output_fields(output)
          dialog = output[/^DIALOG: (.*)$/, 1]
          dialog = nil if dialog.nil? || dialog.strip == 'none'

          dialog_type = output[/^DIALOG_TYPE: (.*)$/, 1]&.strip
          dialog_type = nil if dialog_type.to_s.casecmp('none').zero?
          dialog_type = dialog_type&.to_sym
          dismiss_action = output[/^DISMISS_ACTION: (.*)$/, 1]
          dismiss_action = DISMISS_ACTIONS[dismiss_action] if dismiss_action

          dialog_info = classify_dialog(dialog)
          dialog_type ||= dialog_info && dialog_info[:type]
          dismiss_action ||= dialog_info && dialog_info[:action]

          log = output[/--- LOG ---\s*(.*)\z/m, 1].to_s

          { crashed:        output[/^CRASHED: (.*)$/, 1].to_s.strip == 'yes',
            dialog:         dialog,
            dialog_type:    dialog_type,
            dismiss_action: dismiss_action,
            exited_cleanly: output[/^EXITED_CLEANLY: (.*)$/, 1].to_s.strip == 'yes',
            loaded:         document_loaded?(log),
            log:            log,
            messages:       output.scan(/^MESSAGE: (.*)$/).flatten,
            output:         output,
            saved:          output[/^SAVED: (.*)$/, 1].to_s.strip == 'yes',
            saved_path:     output[/^SAVED_PATH: (.*)$/, 1],
            updater:        output[/^UPDATER: (.*)$/, 1].to_s.strip == 'yes' }
        end

        # Whether the set was loaded.
        #
        # The set is loaded when the application says that it has loaded the document it was
        # given. It says so even when the document could not be loaded, so the failure is
        # looked for as well.
        #
        # @param log [String] the log of the application
        # @return [Boolean] true when the set was loaded
        def document_loaded?(log)
          log.include?('Loading command-line document: done.') &&
            !log.include?('Failed to load command-line document')
        end
      end
    end
  end
end
