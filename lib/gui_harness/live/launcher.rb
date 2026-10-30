# frozen_string_literal: true

require_relative '../generic/launcher'
require_relative 'dialog'
require_relative 'result'
require_relative 'shutdown'

module GuiHarness
  module Live
    # Drives Ableton Live on Windows.
    #
    # This is the generic launcher with the knowledge of Live put in: Live's log is where its
    # dialogs are read, Live's recovery prompt and its installer prompt are handled there,
    # and Live is shut down by the ladder of the Live layer.
    class Launcher < Generic::Launcher
      # The result of a run of Live.
      Result = Live::Result

      class << self
        # The family of a dialog of Live, and the action that answers it.
        #
        # @param text [String, nil] the text the user sees
        # @return [Hash, nil] the family and the action, or nil when there is no text
        def classify_dialog(text)
          Dialog.classify text
        end

        # The rungs the shutdown ladder of Live is climbed by.
        #
        # @return [Array] the rungs, in the order they are climbed
        def shutdown_rungs
          Shutdown::RUNGS
        end

        # The assets of the Live layer, by the path they are written to.
        #
        # The generic assets are written as well, because the Live library dot-sources the
        # generic library.
        #
        # @return [Hash] the source of each asset, by its path
        def assets
          super.merge(
            'live/gui_harness_live.ps1' => asset('live/gui_harness_live.ps1'),
            'live/run.ps1'              => asset('live/run.ps1')
          )
        end

        # The script the run of Live is started with.
        #
        # @return [String] the path of the script, relative to the sidecar
        def entry_point
          'live/run.ps1'
        end

        private

        # The result of a run, as the launcher wrote it down.
        #
        # @param output [String] the output of the launcher
        # @param status [Object] the status of the launcher
        # @return [Result] the result of the run
        def parse(output, status)
          clean_output = output.gsub("\r\n", "\n")
          fields = output_fields(clean_output)

          # Live fetches the update of its own version while it runs and installs it when it
          # exits. The user is told, so that the change to the machine is not a surprise.
          message = update_message(clean_output, fields[:log])
          fields[:messages] << message if message

          Result.new(exit_code: status.exitstatus, **fields)
        end

        # The message that tells the user that an update is going to be installed.
        #
        # Live fetches the update of its own version while it runs, and installs it when it
        # exits. Only the current version of Live has updates: the updater of an old version has
        # nothing to offer.
        #
        # @param output [String] the output of the launcher
        # @param log [String] the log of the application
        # @return [String, nil] the message, or nil when no update is waiting
        def update_message(output, log)
          update = output[/^PENDING_UPDATE: (.*)$/, 1].to_s.strip
          return nil if update.empty?

          version = log[/Init: Version: 'Live ([0-9.]+)/, 1] || log[/Started: Live ([0-9.]+)/, 1]
          subject = version ? "Live #{version}" : 'Live'
          "#{subject} will install update #{update} automatically when it exits."
        end
      end
    end
  end
end
