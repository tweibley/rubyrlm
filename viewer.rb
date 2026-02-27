#!/usr/bin/env ruby
# Thin launcher for RubyRLM web viewer
# Usage: ruby viewer.rb [-p PORT]

require_relative "lib/rubyrlm"
require_relative "lib/rubyrlm/web/app"

port = ARGV.include?("-p") ? ARGV[ARGV.index("-p") + 1].to_i : 8080
RubyRLM::Web::App.run! port: port
