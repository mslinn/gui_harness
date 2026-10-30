# frozen_string_literal: true

require_relative '../generic/result'

module GuiHarness
  module Live
    # The result of a run of Live.
    #
    # The result of the generic layer says that the program ran and that nothing blocked it.
    # Live is different, and the difference belongs to this layer: Live says in its log when it
    # has loaded the document it was given, so a run in which it did not is a run that loaded
    # nothing. Live 11 quits at once when it is handed a file that does not exist, and it logs
    # nothing about the failure, so there is no dialog to report either; the outcome is what
    # says the run came to nothing.
    class Result < Generic::Result
      # What the run amounted to.
      #
      # @return [Symbol] :loaded, :crashed, :blocked or :unknown
      def outcome
        return :unknown if dialog.nil? && !crashed && !loaded

        super
      end
    end
  end
end
