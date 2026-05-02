# frozen_string_literal: true

require_relative 'lib/async/caldav/version'

Gem::Specification.new do |spec|
  spec.name = 'async-caldav'
  spec.version = Async::Caldav::VERSION
  spec.authors = ['Nathan K']
  spec.email = ['nathankidd@hey.com']

  spec.summary = 'CalDAV/CardDAV server for the async ecosystem'

  spec.description = <<~DESC
    Native server for CalDAV/CardDAV.
    Built on protocol-caldav for wire-format concerns.
  DESC

  spec.homepage = 'https://github.com/n-at-han-k/caldav'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.glob('lib/async/**/*').select { |f| File.file?(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'protocol-caldav', '~> 0.1'
end
