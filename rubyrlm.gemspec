require_relative "lib/rubyrlm/version"

Gem::Specification.new do |spec|
  spec.name = "rubyrlm"
  spec.version = RubyRLM::VERSION
  spec.authors = ["Taylor Weibley"]
  spec.email = ["taylor@taylorw.com"]

  spec.summary = "Recursive Language Models for Ruby"
  spec.description = "A Ruby MVP of Recursive Language Models with Gemini backend and a local REPL."
  spec.homepage = "https://github.com/tweibley/rubyrlm"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*", "README.md", "LICENSE*", "CHANGELOG*"]
  end
  spec.bindir = "bin"
  spec.executables = ["rubyrlm"]
  spec.require_paths = ["lib"]

  spec.add_dependency "sinatra", "~> 4.2"
  spec.add_dependency "puma", "~> 7.2"
  spec.add_dependency "rackup"
  spec.add_dependency "kramdown", "~> 2.4"
  spec.add_dependency "kramdown-parser-gfm", "~> 1.1"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "webmock", "~> 3.23"
  spec.add_development_dependency "irb"
end
