# frozen_string_literal: true

module Caldav
  module ForwardAuth
    # Rack middleware that reads Authelia/Authentik forward-auth headers
    # and sets env['dav.user'] from the Remote-User header.
    #
    # Authelia sets these headers after successful authentication:
    #   Remote-User, Remote-Email, Remote-Name, Remote-Groups
    #
    # Usage:
    #   use Caldav::ForwardAuth::Middleware
    #
    class Middleware
      ENV_KEY = "authelia.user"

      def initialize(app)
        @app = app
      end

      def call(env)
        uid = env["HTTP_REMOTE_USER"]

        if uid.present?
          attrs = {
            uid:          uid,
            email:        env["HTTP_REMOTE_EMAIL"],
            display_name: env["HTTP_REMOTE_NAME"],
            groups:       parse_groups(env["HTTP_REMOTE_GROUPS"]),
          }
          env[ENV_KEY] = attrs
          env["dav.user"] = uid
        else
          env[ENV_KEY] = nil
          env["dav.user"] = nil
        end

        @app.call(env)
      end

      private

      def parse_groups(raw)
        return [] if raw.blank?

        raw.split(",").map(&:strip).reject(&:blank?)
      end
    end

    # Development/test stub that auto-creates a user without requiring
    # real Authelia headers.  Falls back to headers if present.
    class TestStub < Middleware
      DEFAULT_UID   = "dev"
      DEFAULT_EMAIL = "dev@localhost"
      DEFAULT_NAME  = "Developer"

      def call(env)
        # If real headers are present, use them (e.g. test suite)
        unless env["HTTP_REMOTE_USER"].present?
          env["HTTP_REMOTE_USER"]   = DEFAULT_UID
          env["HTTP_REMOTE_EMAIL"]  = DEFAULT_EMAIL
          env["HTTP_REMOTE_NAME"]   = DEFAULT_NAME
          env["HTTP_REMOTE_GROUPS"] = "developers"
        end

        super
      end
    end
  end
end
