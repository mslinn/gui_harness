# frozen_string_literal: true

require_relative '../generic/shutdown'

module GuiHarness
  module Live
    # The ladder Ableton Live is shut down by.
    #
    # The ladder of Live is the ladder of the generic layer with the rungs of Live put in.
    class Shutdown < Generic::Shutdown
      # The rungs of the Live ladder, in the order they are climbed.
      #
      # 1. `close_windows` — ask Live to close, the way a person closes it.
      # 2. `answer_save_prompt` — answer Live's "Save changes?" from Live's log: `No`, or
      #    `Yes` when the set is to be saved in place.
      # 3. `wait_for_exit` — wait for the process tree to go away by itself.
      # 4. `confirm_clean_exit` — Live's log says it quit normally.
      # 5. `stop_tree` — stop what is left, as the last resort.
      RUNGS = %i[close_windows answer_save_prompt wait_for_exit confirm_clean_exit stop_tree].freeze
    end
  end
end
