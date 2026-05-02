# frozen_string_literal: true

require_relative 'lib/protocol/caldav/version'

Gem::Specification.new do |spec|
  spec.name = 'protocol-caldav'
  spec.version = Protocol::Caldav::VERSION
  spec.authors = ['Nathan K']
  spec.email = ['nathankidd@hey.com']

  spec.summary = 'CalDAV/CardDAV wire protocol: XML rendering, path semantics, ETags, filters'

  spec.description = <<~DESC
    Pure protocol code for CalDAV (RFC 4791) and CardDAV (RFC 6352).
    No rack, no async, no I/O. Pair with async-caldav for a server.
  DESC

  spec.homepage = 'https://github.com/n-at-han-k/caldav'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.glob('lib/**/*').select { |f| File.file?(f) }
  spec.require_paths = ['lib']

  # REXML is a Ruby stdlib bundled gem -- needed for filter XML parsing only.
  # Lazy-loaded in filter/parser.rb so code that doesn't parse filters never loads it.
  spec.add_dependency 'rexml'
end
