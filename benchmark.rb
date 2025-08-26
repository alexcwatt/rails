# frozen_string_literal: true

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"

  gem "rails", path: "."
  gem "benchmark-ips"
end

require "active_support/parameter_filter"

KEYS_CASE_INSENSITIVE_PARTIAL_MATCH = [
  "access_proxy_token",
  "access_token",
  "access-token",
  "accesstoken",
  "account_email",
  "account_sid",
  "api_key",
  "api_token",
  "Api-Token",
  "auth_token",
  "authorization",
  "authtoken",
  "password",
  "SAMLResponse",
  "secret",
  "ssn",
  "raw_payload",
  "client_secret",
  "jwt_token",
  "bearer_token",
  "oauth_token",
  "refresh_token",
  "session_key",
  "private_key",
  "public_key",
  "encryption_key",
  "signing_key",
  "webhook_secret",
  "database_password",
  "redis_password",
  "smtp_password",
  "ldap_password",
  "admin_password",
  "root_password",
  "user_credentials",
  "login_credentials",
  "authentication_token",
  "verification_token",
].map { |pattern| /(?i:#{Regexp.escape(pattern.to_s)})/ }.freeze

PARAMETER_FILTER = ActiveSupport::ParameterFilter.new(
  KEYS_CASE_INSENSITIVE_PARTIAL_MATCH,
)

def example_data
  {
    "foo" => { "bar" => "baz", "baz" => "bar" },
    "bar" => { "baz" => "foo", "verification_token" => "baz" },
    "baz" => "foo",
  }
end

Benchmark.ips do |x|
  x.report("filter") do
    PARAMETER_FILTER.filter(example_data)
  end
end
