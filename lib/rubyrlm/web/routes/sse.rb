require "json"

module RubyRLM
  module Web
    module Routes
      module SSE
        def self.registered(app)
          app.post "/api/query" do
            content_type :json
            begin
              body = JSON.parse(request.body.read, symbolize_names: true)
            rescue JSON::ParserError
              halt 400, JSON.generate(error: "Invalid JSON body")
            end

            prompt = body[:prompt].to_s
            halt 400, JSON.generate(error: "prompt is required") if prompt.strip.empty?
            fork = body[:fork] == true
            session_id = body[:session_id].to_s.strip
            session_id = nil if session_id.empty?
            environment = (body[:environment] || "local").to_s.strip
            environment = "local" if environment.empty?
            environment_options = body[:environment_options] || body[:environmentOptions] || {}
            environment_options = {} unless environment_options.is_a?(Hash)

            if session_id && !fork
              existing = settings.session_loader.load_session(session_id)
              halt 404, JSON.generate(error: "Session not found") unless existing
            end

            model_name = body[:model_name]&.to_s&.strip
            model_name = "gemini-3.1-pro-preview" if model_name.nil? || model_name.empty?

            begin
              run_id = settings.query_service.start_run(
                prompt: prompt,
                model_name: model_name,
                max_iterations: body[:max_iterations]&.to_i || 30,
                iteration_timeout: body[:iteration_timeout]&.to_i || 60,
                max_depth: body[:max_depth]&.to_i || 1,
                temperature: body[:temperature]&.to_f || 0.5,
                thinking_level: body[:thinking_level] || body[:thinkingLevel],
                session_id: session_id,
                fork: fork,
                environment: environment,
                environment_options: environment_options
              )
            rescue ArgumentError, RubyRLM::ConfigurationError => e
              halt 400, JSON.generate(error: e.message)
            end

            JSON.generate({ run_id: run_id, status: "started" })
          end

          app.get "/api/query/:id/stream" do
            content_type "text/event-stream"
            headers "Cache-Control" => "no-cache"

            run_id = params[:id]
            events = settings.query_service.stream_events(run_id)

            if events.nil?
              halt 404, "Run not found"
            end

            stream(:keep_open) do |out|
              begin
                events.each do |event|
                  event_type = event[:type] || event["type"] || "message"
                  out << "event: #{event_type}\ndata: #{JSON.generate(event)}\n\n"
                end
              rescue IOError
                # Client disconnected mid-stream. Cancel the background run
                # so we do not leak a live worker and active run entry.
                settings.query_service.cancel_run(run_id)
              rescue StandardError
                settings.query_service.cancel_run(run_id)
                raise
              end
            end
          end

          app.delete "/api/query/:id" do
            content_type :json
            if settings.query_service.cancel_run(params[:id])
              JSON.generate({ status: "cancelled" })
            else
              halt 404, JSON.generate({ error: "Run not found" })
            end
          end
        end
      end
    end
  end
end
