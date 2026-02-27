require "json"

module RubyRLM
  module Web
    module Routes
      module Api
        def self.registered(app)
          validate_session_id = lambda do |session_id|
            id = session_id.to_s
            if id.include?("/") || id.include?("\\")
              halt 400, JSON.generate(error: "Invalid session ID")
            end
          end

          app.get "/api/sessions" do
            content_type :json
            sessions = settings.session_loader.list_sessions
            JSON.generate(sessions)
          end

          app.get "/api/sessions/:id" do
            session_id = params[:id]
            validate_session_id.call(session_id)

            session = settings.session_loader.load_session(session_id)
            if session
              content_type :json
              JSON.generate(session)
            else
              halt 404, JSON.generate(error: "Session not found")
            end
          end

          app.delete "/api/sessions/:id" do
            session_id = params[:id]
            validate_session_id.call(session_id)

            if settings.session_loader.delete_session(session_id)
              content_type :json
              JSON.generate(status: "deleted", id: session_id)
            else
              halt 404, JSON.generate(error: "Session not found")
            end
          end

          app.get "/api/sessions/:id/raw" do
            session_id = params[:id]
            validate_session_id.call(session_id)

            raw = settings.session_loader.raw_session(session_id)
            if raw
              content_type "text/plain"
              raw
            else
              halt 404, JSON.generate(error: "Session not found")
            end
          end

          app.get "/api/sessions/:id/tree" do
            session_id = params[:id]
            validate_session_id.call(session_id)
            tree = settings.session_loader.build_recursion_tree(session_id)
            content_type :json
            JSON.generate(tree)
          end

          app.get "/api/analytics" do
            content_type :json
            days = params[:days]&.to_i
            since_time = (days && days > 0) ? (Time.now.utc - (days * 86400)) : nil
            analytics = settings.session_loader.aggregate_analytics(since_time: since_time)
            JSON.generate(analytics)
          end

          app.get "/api/sessions/:id1/compare/:id2" do
            validate_session_id.call(params[:id1])
            validate_session_id.call(params[:id2])
            comparison = settings.session_loader.compare_sessions(params[:id1], params[:id2])
            if comparison
              content_type :json
              JSON.generate(comparison)
            else
              halt 404, JSON.generate(error: "One or both sessions not found")
            end
          end

          app.post "/api/sessions/:id/export" do
            session_id = params[:id]
            validate_session_id.call(session_id)
            html = settings.export_service.export_session(session_id, theme: params[:theme] || "light")
            if html
              content_type "text/html"
              attachment "rubyrlm-session-#{session_id[0..7]}.html"
              html
            else
              halt 404, JSON.generate(error: "Session not found")
            end
          end

          app.get "/api/sessions/:id/share.png" do
            session_id = params[:id]
            validate_session_id.call(session_id)
            png = settings.export_service.export_share_png(session_id, theme: params[:theme] || "light")
            if png
              content_type "image/png"
              attachment "rubyrlm-#{session_id[0..7]}.png"
              png
            else
              halt 404, JSON.generate(error: "Session not found or PNG rendering failed")
            end
          end
          app.get "/api/containers" do
            content_type :json
            require "open3"
            stdout, _stderr, status = Open3.capture3("docker", "ps", "--filter", "ancestor=rubyrlm/repl:latest", "--format", "{{json .}}")
            if status.success?
              containers = stdout.lines.filter_map do |line|
                JSON.parse(line) rescue nil
              end
              JSON.generate(containers)
            else
              JSON.generate([])
            end
          end
        end
      end
    end
  end
end
