# frozen_string_literal: true

require_relative '../generic/dialog'

module GuiHarness
  module Live
    # The dialogs of Ableton Live, and the action that answers them.
    #
    # Live is a Qt application and exposes no names for its windows, so its dialogs are read
    # from its log. The wording is Live's own, and the rules of the generic layer are the
    # rules of the dialogs that every program has.
    module Dialog
      # The rules that are particular to Live.
      RULES = [
        {
          action:  nil,
          id:      'updater',
          pattern: /InstallHelper|installing packages/i,
          type:    :updater,
        },
        {
          action:  { type: 'button', value: 'OK' },
          id:      'shutdown',
          pattern: /Live will shut down after this message box is closed\./i,
          type:    :fatal,
        }
      ].freeze

      # Every rule that is looked up in the text of a dialog of Live.
      ALL_RULES = (RULES + Generic::Dialog::RULES).freeze

      class << self
        # The family of a dialog of Live, and the action that answers it.
        #
        # @param text [String, nil] the text the user sees
        # @return [Hash, nil] the family and the action, or nil when there is no text
        def classify(text)
          Generic::Dialog.classify text, ALL_RULES
        end
      end
    end
  end
end
