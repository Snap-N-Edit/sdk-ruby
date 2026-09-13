# frozen_string_literal: true

RSpec.describe Snapnedit::Error do
  it "carries a code and an HTTP status" do
    error = described_class.new("nope", code: Snapnedit::ErrorCodes::NOT_FOUND, status: 404)
    expect([error.message, error.code, error.status]).to eq(["nope", "not_found", 404])
  end

  it "defaults to the internal code" do
    expect(described_class.new("boom").code).to eq("internal")
  end

  it "is a StandardError, so a bare rescue catches it" do
    expect(described_class.new("boom")).to be_a(StandardError)
  end

  it "shows the code and status when inspected" do
    expect(described_class.new("boom", code: "forbidden", status: 403).inspect)
      .to eq('#<Snapnedit::Error code="forbidden" status=403 "boom">')
  end

  describe Snapnedit::TimeoutError do
    it "carries no api code or status — a poll timeout is not an api response" do
      error = described_class.new("gave up")
      expect(error).to be_a(Snapnedit::Error)
      expect([error.code, error.status]).to eq([nil, nil])
    end
  end
end
