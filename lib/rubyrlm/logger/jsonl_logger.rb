require "fileutils"
require "json"
require "time"

module RubyRLM
  module Logger
    class JsonlLogger
      attr_reader :events

      def initialize(log_dir: "./logs")
        @log_dir = log_dir
        @events = []
        FileUtils.mkdir_p(@log_dir) if @log_dir
      end

      def log(event)
        payload = event.merge(timestamp: Time.now.utc.iso8601)
        @events << payload
        return unless @log_dir

        run_id = payload[:run_id] || payload["run_id"] || "unknown"
        path = File.join(@log_dir, "#{run_id}.jsonl")
        File.open(path, "a") { |f| f.puts(JSON.generate(payload)) }
      end
    end
  end
end
