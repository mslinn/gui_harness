# frozen_string_literal: true

module GuiHarness
  module Generic
    # The dialogs of any GUI program, and the action that answers them.
    #
    # The rules are told apart by the text the user sees, and each rule says which button
    # answers the dialog. The generic layer knows of the dialogs that every program has: the
    # program that failed, the file that is not there, and the question whether to save.
    module Dialog
      RULES = [
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
        }
      ].freeze

      class << self
        # The family of a dialog, and the action that answers it.
        #
        # @param text [String, nil] the text the user sees
        # @param rules [Array] the rules the text is looked up in
        # @return [Hash, nil] the family and the action, or nil when there is no text
        def classify(text, rules = RULES)
          return nil if text.nil? || text.strip.empty?

          rule = rules.find { |candidate| text.match?(candidate[:pattern]) }
          return { type: :unknown, action: nil } if rule.nil?

          { type: rule[:type], action: rule[:action]&.dup }
        end
      end
    end
  end
end
