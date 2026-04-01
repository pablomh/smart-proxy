require 'registration/proxy_request'

class Proxy::Registration::Api < ::Sinatra::Base
  # Cache for the global registration script (GET /register).
  #
  # The script is identical for all hosts sharing the same registration
  # parameters (org, location, hostgroup, activation keys), making it safe
  # to serve from an in-memory cache during concurrent bulk registration.
  #
  # Per-key double-checked locking prevents thundering herd while allowing
  # genuinely independent cache keys (e.g. different activation keys) to
  # fetch from Foreman in parallel.
  #
  # Only HTTP 200 responses are cached — errors are raised out of the cache
  # block so they never poison the cache. The per-key mutex is evicted
  # immediately after caching so KEY_MUTEXES stays bounded to keys currently
  # being fetched for the first time (zero under steady state).
  REGISTRATION_SCRIPT_CACHE_TTL = 5 * 60 # seconds
  KEY_MUTEXES                   = Concurrent::Map.new
  SCRIPT_CACHE                  = Concurrent::Map.new

  class ScriptFetchError < StandardError
    attr_reader :response

    def initialize(response)
      super()
      @response = response
    end
  end

  class << self
    def registration_script_cache
      SCRIPT_CACHE
    end

    def key_mutex(cache_key)
      KEY_MUTEXES.compute_if_absent(cache_key) { Mutex.new }
    end

    def evict_key_mutex(cache_key)
      KEY_MUTEXES.delete(cache_key)
    end
  end

  get '/' do
    registration_script
  rescue ScriptFetchError => e
    handle_response(e.response)
  rescue StandardError => e
    logger.exception "Error when rendering Global Registration Template", e
    render_error(default_error_msg)
  end

  post '/' do
    response = Proxy::Registration::ProxyRequest.new.host_register(request)
    handle_response(response)
  rescue StandardError => e
    logger.exception "Error when rendering Host Registration Template", e
    render_error(default_error_msg)
  end

  private

  def registration_script
    cache_key = Rack::Utils.build_query(
      Rack::Utils.parse_nested_query(request.query_string).sort_by { |k, _| k }
    )
    cache(cache_key) do
      response = Proxy::Registration::ProxyRequest.new.global_register(request)
      raise ScriptFetchError, response unless response.code == '200'
      response.body
    end
  end

  def cache(key, &block)
    value = read_registration_cache(key)
    return value if value

    self.class.key_mutex(key).synchronize do
      value = read_registration_cache(key)
      return value if value

      result = yield
      self.class.registration_script_cache[key] = { body: result, at: Time.now }
      self.class.evict_key_mutex(key)
      result
    end
  end

  def read_registration_cache(cache_key)
    entry = self.class.registration_script_cache[cache_key]
    entry[:body] if entry && (Time.now - entry[:at]) < REGISTRATION_SCRIPT_CACHE_TTL
  end

  def handle_response(response)
    if response.code.start_with?('2')
      response.body
    else
      message = response["content-type"].include?('text/plain') ? response.body : default_error_msg
      render_error(message, code: response.code)
    end
  end

  def render_error(message, code: 500)
    status code
    message
  end

  def default_error_msg
    "echo \"Internal Server Error\"\nexit 1\n"
  end
end
