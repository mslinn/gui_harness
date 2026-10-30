# frozen_string_literal: true

module GuiHarness
  module Generic
    # The ladder an application is shut down by.
    #
    # Ruby holds the order of the rungs, and PowerShell holds what each rung does. The
    # launcher hands the rungs to the sidecar, and the sidecar climbs them.
    class Shutdown
      # The rungs of the generic ladder, in the order they are climbed.
      #
      # 1. `close_windows` — ask the application to close, the way a person closes it.
      # 2. `wait_for_exit` — wait for the process tree to go away by itself.
      # 3. `stop_tree` — stop what is left, as the last resort.
      RUNGS = %i[close_windows wait_for_exit stop_tree].freeze
    end
  end
end
