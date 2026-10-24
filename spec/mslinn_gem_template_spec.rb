# frozen_string_literal: false

require 'spec_helper'

RSpec.describe MslinnGemTemplate do
  it 'has a version constant' do
    expect(described_class::VERSION).to be_a(String)
  end
end
