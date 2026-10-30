# frozen_string_literal: true

module GuiHarness
  module Generic
    # The result of a run.
    #
    # The result is a plain data structure, so that a test suite can assert on it without
    # knowing anything about the windows of the application.
    Result = Struct.new(:exit_code, :output, :dialog, :dialog_type, :dismiss_action, :log, :loaded, :crashed,
                        :saved, :saved_path, :updater, :exited_cleanly, :messages, keyword_init: true) do
      # Whether the run was a success.
      #
      # @return [Boolean] true when the application did what it was asked to do
      def success?
        exit_code.to_i.zero? && dialog.nil? && !crashed
      end

      # What the run amounted to.
      #
      # @return [Symbol] :loaded, :crashed, :blocked or :unknown
      def outcome
        return :loaded if exit_code.to_i.zero? && !crashed && dialog.nil?
        return :crashed if crashed || dialog_type == :fatal
        return :unknown if dialog_type == :unknown
        return :blocked if dialog_type && dialog_type != :fatal

        :unknown
      end
    end
  end
end
