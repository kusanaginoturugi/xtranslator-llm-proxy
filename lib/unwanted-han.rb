# frozen_string_literal: true

module UnwantedHan
  CHARACTERS = File.read(File.expand_path("../data/unwanted-simplified-han.txt", __dir__), encoding: "UTF-8").strip
  PATTERN = Regexp.new("[#{Regexp.escape(CHARACTERS)}]")

  module_function

  def included?(text)
    text.match?(PATTERN)
  end
end
