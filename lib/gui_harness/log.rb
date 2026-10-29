# frozen_string_literal: true

require 'logger'

module GuiHarness
  # The harness's logger.
  #
  # The logger is a constant of GuiHarness, and not a top-level one, because a program that uses
  # the harness has a logger of its own, and the harness does not take it over.
  #
  # The debug output of a launch is a stream of window and process states, and it is of no use to
  # anyone who is not reading it, so it is written only when the harness is being debugged.
  module Log
    class << self
      # Writes a debug message.
      #
      # @param message [String] the message
      # @return [void]
      def debug(message)
        logger.debug message
      end

      # The logger the harness writes to.
      #
      # @return [Logger] the logger
      def logger
        @logger ||= Logger.new($stderr).tap do |logger|
          logger.level = debug? ? Logger::DEBUG : Logger::FATAL
          logger.formatter = proc do |severity, _time, _progname, message|
            "[gui_harness] #{severity}: #{message}\n"
          end
        end
      end

      private

      # @return [Boolean] true if the harness is being debugged
      def debug?
        ENV['GUI_HARNESS_DEBUG'] == '1' || ENV['DEBUG'] == '1'
      end
    end
  end
end
