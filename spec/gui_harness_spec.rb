# frozen_string_literal: false

require 'spec_helper'

RSpec.describe GuiHarness do
  it 'has a version constant' do
    expect(described_class::VERSION).to be_a(String)
  end
end
