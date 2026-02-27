require "sinatra/base"
require_relative "services/session_loader"
require_relative "services/streaming_logger"
require_relative "services/query_service"
require_relative "services/export_service"
require_relative "routes/api"
require_relative "routes/pages"
require_relative "routes/sse"

module RubyRLM
  module Web
    class App < Sinatra::Base
      set :public_folder, File.expand_path("public", __dir__)
      set :log_dir, ENV.fetch("RUBYRLM_LOG_DIR", "./logs")
      set :bind, "0.0.0.0"
      set :server, :puma
      # Use Puma cluster mode (1 worker) to avoid single-mode boot.
      # Keep worker count at 1 because in-flight runs are tracked in-process.
      set :server_settings, {
        workers: 1,
        silence_single_worker_warning: true
      }

      configure :development do
        require "sinatra/reloader"
        register Sinatra::Reloader
        also_reload File.expand_path("{services,routes}/*.rb", __dir__)
      end

      configure do
        set :session_loader, Services::SessionLoader.new(log_dir: settings.log_dir)
        set :query_service, Services::QueryService.new(log_dir: settings.log_dir)
        set :export_service, Services::ExportService.new(session_loader: settings.session_loader)
      end

      register Routes::Api
      register Routes::Pages
      register Routes::SSE
    end
  end
end
