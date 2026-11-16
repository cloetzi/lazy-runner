# frozen_string_literal: true

require "test_helper"

describe SetupCode do
  after { SetupCode.consume! }

  it "makes a code of 26 characters in groups of five, with nothing that reads like another" do
    code = SetupCode.generate!

    _(code).must_match(/\A([A-Z0-9]{5}-){5}[A-Z0-9]\z/)
    _(code.delete("-").chars - SetupCode::ALPHABET).must_be_empty
    _(code).wont_match(/[01ILOU]/)
  end

  it "matches the code however it is typed" do
    code = SetupCode.generate!

    _(SetupCode.match?(code)).must_equal true
    _(SetupCode.match?(" #{code.downcase.delete("-")} ")).must_equal true
    _(SetupCode.match?(code.succ)).must_equal false
    _(SetupCode.match?(nil)).must_equal false
  end

  it "keeps only the latest code, until it is used" do
    first = SetupCode.generate!
    second = SetupCode.generate!

    _(SetupCode.match?(first)).must_equal false
    _(SetupCode.match?(second)).must_equal true
    SetupCode.consume!
    _(SetupCode.active?).must_equal false
    _(SetupCode.match?(second)).must_equal false
  end
end
