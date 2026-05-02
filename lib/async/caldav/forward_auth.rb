# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "async/caldav"

module Async
  module Caldav
    module ForwardAuth
      module_function

      def extract(env)
        {
          user: env['HTTP_REMOTE_USER'],
          email: env['HTTP_REMOTE_EMAIL'],
          name: env['HTTP_REMOTE_NAME'],
          groups: parse_groups(env['HTTP_REMOTE_GROUPS'])
        }
      end

      def parse_groups(header)
        return [] if header.nil? || header.empty?
        header.split(',').map(&:strip).reject(&:empty?)
      end

      private_class_method :parse_groups
    end

    module TestStub
      module_function

      def inject(env, user: 'admin', email: nil, name: nil, groups: nil)
        env['HTTP_REMOTE_USER'] ||= user
        env['HTTP_REMOTE_EMAIL'] ||= email if email
        env['HTTP_REMOTE_NAME'] ||= name if name
        env['HTTP_REMOTE_GROUPS'] ||= groups if groups
        env
      end
    end
  end
end


test do
  describe "Async::Caldav::ForwardAuth" do
    it "sets user from HTTP_REMOTE_USER" do
      result = Async::Caldav::ForwardAuth.extract({ 'HTTP_REMOTE_USER' => 'admin' })
      result[:user].should.equal 'admin'
    end

    it "leaves user nil when header absent" do
      result = Async::Caldav::ForwardAuth.extract({})
      result[:user].should.be.nil
    end

    it "parses HTTP_REMOTE_GROUPS as comma-separated list" do
      result = Async::Caldav::ForwardAuth.extract({ 'HTTP_REMOTE_GROUPS' => 'a,b,c' })
      result[:groups].should.equal ['a', 'b', 'c']
    end

    it "trims whitespace around group names" do
      result = Async::Caldav::ForwardAuth.extract({ 'HTTP_REMOTE_GROUPS' => ' a , b ' })
      result[:groups].should.equal ['a', 'b']
    end

    it "empty groups header produces empty list" do
      result = Async::Caldav::ForwardAuth.extract({ 'HTTP_REMOTE_GROUPS' => '' })
      result[:groups].should.equal []
    end

    it "email and name flow through" do
      result = Async::Caldav::ForwardAuth.extract({
        'HTTP_REMOTE_EMAIL' => 'a@b.com',
        'HTTP_REMOTE_NAME' => 'Admin'
      })
      result[:email].should.equal 'a@b.com'
      result[:name].should.equal 'Admin'
    end
  end

  describe "Async::Caldav::TestStub" do
    it "injects defaults when no header present" do
      env = {}
      Async::Caldav::TestStub.inject(env)
      env['HTTP_REMOTE_USER'].should.equal 'admin'
    end

    it "respects existing headers when present" do
      env = { 'HTTP_REMOTE_USER' => 'existing' }
      Async::Caldav::TestStub.inject(env)
      env['HTTP_REMOTE_USER'].should.equal 'existing'
    end
  end
end
