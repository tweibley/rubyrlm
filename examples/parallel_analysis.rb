$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "rubyrlm"

api_key = ENV["GEMINI_API_KEY"]
if api_key.to_s.strip.empty?
  warn "GEMINI_API_KEY is missing in environment."
  exit 1
end

# --- Build a synthetic dataset: 5 product reviews to analyze in parallel ---

reviews = {
  "Wireless Headphones" => "Great sound quality and battery life. The noise cancellation is decent but not as good as Sony or Bose. Comfortable for long sessions. The app is buggy and crashes often. Worth the price at $79.",
  "Standing Desk" => "Solid build quality. The motor is quiet and lifts smoothly. Took about 45 minutes to assemble. The cable management tray is flimsy. Memory presets are a nice touch. Wobbles slightly at max height.",
  "Mechanical Keyboard" => "The switches feel amazing — went with Cherry MX Browns. RGB lighting is customizable but the software only works on Windows. Keycaps started showing shine after 3 months. No wrist rest included.",
  "Portable Monitor" => "Perfect for travel. 1080p IPS panel looks sharp. USB-C connection works great with my laptop. Brightness is too low for outdoor use. The kickstand is wobbly. Speakers are terrible but that's expected.",
  "Ergonomic Mouse" => "Completely eliminated my wrist pain after 2 weeks. Takes a few days to get used to the vertical grip. Bluetooth connection drops occasionally. Side buttons are hard to reach. Battery lasts about 3 months."
}

context = {
  task: "Analyze these product reviews. For each product, extract: sentiment (positive/mixed/negative), key pros, key cons, and a 1-sentence summary. Then provide an overall ranking from best to worst reviewed.",
  reviews: reviews
}

# --- Configure the client with new features ---

client = RubyRLM::Client.new(
  backend: "gemini",
  model_name: "gemini-3.1-pro-preview",        # capable model for orchestration
  api_key: api_key,
  max_depth: 1,                         # allow one level of recursive subcalls
  max_iterations: 15,

  # Cross-model routing: subcalls use a cheaper model by default
  subcall_model: "gemini-3.1-flash-lite-preview",

  # Budget guards: cap cost and subcalls across the entire recursion tree
  budget: {
    max_subcalls: 25,
    max_cost_usd: 0.50
  },

  # Context compaction: compress older messages if history grows long
  compaction: true,
  compaction_threshold: 0.6,

  verbose: true
)

# --- Run the analysis ---

puts "Analyzing #{reviews.size} product reviews..."
puts "  Model: gemini-3.1-pro-preview (orchestrator) + gemini-3.1-flash-lite-preview (subcalls)"
puts "  Budget: max 25 subcalls, $0.50 cost cap"
puts

result = client.completion(
  prompt: context,
  root_prompt: <<~HINT
    Use parallel_queries to analyze all reviews concurrently with a cheaper model.
    Each subcall should extract sentiment, pros, cons, and a summary for one product.
    Then aggregate the results and rank the products.
  HINT
)

# --- Display results ---

puts "\n#{"=" * 60}"
puts "ANALYSIS RESULTS"
puts "=" * 60
puts result.response

puts "\n#{"=" * 60}"
puts "EXECUTION METADATA"
puts "=" * 60
iterations = result.metadata[:iterations]
puts "  Iterations:  #{iterations.is_a?(Array) ? iterations.size : iterations}"
puts "  Model:       #{result.metadata[:model_name]}"

if result.metadata[:budget]
  b = result.metadata[:budget]
  puts "  Subcalls:    #{b[:subcalls]}#{b.dig(:limits, :max_subcalls) ? " / #{b[:limits][:max_subcalls]} max" : ""}"
  puts "  Total cost:  $#{"%.4f" % b[:total_cost]}#{b.dig(:limits, :max_cost_usd) ? " / $#{"%.2f" % b[:limits][:max_cost_usd]} max" : ""}"
  puts "  Tokens:      #{b[:total_tokens]}"
end

if result.metadata[:compaction_events]&.any?
  puts "  Compactions: #{result.metadata[:compaction_events].length}"
  result.metadata[:compaction_events].each do |evt|
    puts "    #{evt[:messages_before]} msgs → #{evt[:messages_after]} msgs"
  end
end

puts "\n=== Usage ==="
puts result.usage_summary.to_h
