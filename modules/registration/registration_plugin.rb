module Proxy::Registration
  class Plugin < ::Proxy::Plugin
    rackup_path File.expand_path("http_config.ru", File.expand_path(__dir__))

    plugin :registration, ::Proxy::VERSION
    requires :templates, ::Proxy::VERSION

    load_programmable_settings do |settings|
      settings[:registration_url]&.chomp!('/')
      settings
    end

    validate :registration_url, optional_url: true
    expose_setting :registration_url

    # Optional Redis URL for sharing the registration script cache across
    # multiple capsule nodes in an LB pool. When set, all nodes read from
    # and write to the same Redis instance so a single warm request benefits
    # every node. Falls back to per-node in-memory cache if unset or if
    # Redis is unreachable. Requires the 'redis' gem to be installed.
    # Example: redis://lb-host:6379/0
    validate :redis_url, optional_url: true
  end
end
