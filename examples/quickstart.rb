$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "rubyrlm"

api_key = ENV["GEMINI_API_KEY"]
if api_key.to_s.strip.empty?
  warn "GEMINI_API_KEY is missing in environment."
  exit 1
end

client = RubyRLM::Client.new(
  backend: "gemini",
  model_name: "gemini-3.1-pro-preview",
  api_key: api_key,
  max_depth: 1,
  max_iterations: 20,
  logger: RubyRLM::Logger::JsonlLogger.new(log_dir: "./logs"),
  verbose: true
)

prompt = "Compute 2^(2^(2^2)) using Ruby code and provide the exact integer."
result = client.completion(prompt: prompt)

puts "\n=== Final Answer ==="
puts result.response
puts "\n=== Usage ==="
puts result.usage_summary.to_h
