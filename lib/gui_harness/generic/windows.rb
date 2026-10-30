# frozen_string_literal: true

require 'open3'

module GuiHarness
  module Generic
    # The Windows machine, as WSL sees it.
    #
    # The harness is run from WSL, and the application it drives runs on Windows, so the
    # paths of the two are not the same, and the paths have to be translated.
    module Windows
      # The methods stay public instance methods, so that a launcher can extend the module
      # and offer them as its own.
      extend self # rubocop:disable Style/ModuleFunction

      # The path of a file, as Windows sees it.
      #
      # @param path [String] the path of the file
      # @return [String] the path, as Windows sees it
      def windows_path(path)
        return path if path.match?(%r{\A[A-Za-z]:[\\/]})
        return path unless path.include?('/') || File.exist?(path)

        absolute = File.expand_path path
        out, status = Open3.capture2e 'wslpath', '-w', absolute
        status.success? ? out.strip : absolute
      end

      # Whether the program can be launched.
      #
      # @param executable [String, nil] the path of the program
      # @return [Boolean] whether the program is there
      def available?(executable)
        return false if executable.nil?
        return false unless File.exist?(executable)

        _, status = Open3.capture2e 'powershell.exe', '-NoProfile', '-Command', 'exit 0'
        status.success?
      rescue Errno::ENOENT
        false
      end

      # The Windows temporary directory, as WSL sees it.
      #
      # @return [String] the path of the directory
      def windows_directory
        @windows_directory ||= begin
          dir = ENV['TEMP'] || ENV['TMP'] || 'C:\Windows\Temp'
          wsl = windows_path dir
          wsl.start_with?('/mnt/') ? wsl : '/mnt/c/Windows/Temp'
        end
      end
    end
  end
end
