# frozen_string_literal: true

require_relative 'lib/async/caldav/version'

Gem::Specification.new do |spec|
  spec.name = 'caldav'
  spec.version = Async::Caldav::VERSION
  spec.authors = ['Nathan K']
  spec.email = ['nathankidd@hey.com']

  spec.summary = 'CalDAV/CardDAV server'

  spec.description = <<~DESC
    CalDAV/CardDAV server. Umbrella gem that pulls in protocol-caldav and async-caldav.
  DESC

  spec.homepage = 'https://github.com/n-at-han-k/caldav'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['documentation_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.glob('{lib,exe}/**/*').select { |f| File.file?(f) } +
               %w[caldav.gemspec Gemfile LICENSE]
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'rexml'
  spec.add_dependency "scampi", "~> 0.1.7"

  spec.add_development_dependency 'base64'
end
