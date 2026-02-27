require "json"

module RubyRLM
  module Repl
    class DockerRepl
      module Protocol
        CONTAINER_PORT = 9867

        TYPE_INIT = "init"
        TYPE_INIT_OK = "init_ok"
        TYPE_EXECUTE = "execute"
        TYPE_EXECUTE_RESULT = "execute_result"

        module_function

        def encode(message)
          "#{JSON.generate(message)}\n"
        end

        def decode(line)
          JSON.parse(line.to_s, symbolize_names: true)
        end
      end
    end
  end
end
