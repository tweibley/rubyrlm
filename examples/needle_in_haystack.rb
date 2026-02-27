$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "rubyrlm"
require "securerandom"

api_key = ENV["GEMINI_API_KEY"]
if api_key.to_s.strip.empty?
  warn "GEMINI_API_KEY is missing in environment."
  exit 1
end

rng = Random.new(42)
needle = rng.rand(100_000..999_999)
haystack_lines = []
2000.times do |i|
  haystack_lines << "line_#{i}: #{SecureRandom.hex(8)} #{SecureRandom.hex(8)}"
end
insert_at = rng.rand(0...haystack_lines.length)
haystack_lines[insert_at] = "line_#{insert_at}: SECRET_NUMBER=#{needle}"

context = {
  task: "Find the secret number in the haystack content.",
  haystack: haystack_lines.join("\n"),
  expected_format: "Return only the integer."
}

client = RubyRLM::Client.new(
  backend: "gemini",
  model_name: "gemini-3.1-pro-preview",
  api_key: api_key,
  max_depth: 1,
  max_iterations: 25,
  logger: RubyRLM::Logger::JsonlLogger.new(log_dir: "./logs"),
  verbose: true
)

result = client.completion(
  prompt: context,
  root_prompt: "Use Ruby code to search context efficiently, then return only the integer."
)

puts "\n=== Found Answer ==="
puts result.response
puts "Expected: #{needle}"
