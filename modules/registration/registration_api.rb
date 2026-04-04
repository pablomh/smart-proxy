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

    # Returns a Redis client when :redis_url is configured, nil otherwise.
    # Lazy-initialised; falls back to nil on LoadError (gem not installed)
    # or connection error, so in-memory cache remains the fallback.
    def redis_client
      return @redis_client if instance_variable_defined?(:@redis_client)

      redis_url = Proxy::Registration::Plugin.settings.redis_url
      @redis_client = if redis_url
                        require 'redis'
                        Redis.new(url: redis_url)
                      end
    rescue LoadError
      @redis_client = nil
    rescue => e
      ::Proxy::Log.logger.warn "Registration: Redis init failed (#{e.class}: #{e.message}); using local cache"
      @redis_client = nil
    end
  end

  get '/health' do
    content_type :json
    if Proxy::Registration::ProxyRequest.new.foreman_reachable?
      { status: 'ok' }.to_json
    else
      status 503
      { status: 'error', message: 'Foreman is unreachable' }.to_json
    end
  rescue StandardError => e
    logger.exception 'Error during health check', e
    status 503
    content_type :json
    { status: 'error', message: 'Health check failed' }.to_json
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

      # Write to Redis first (shared across all capsule nodes in the LB pool)
      if (redis = self.class.redis_client)
        begin
          redis.setex(key, REGISTRATION_SCRIPT_CACHE_TTL, result)
        rescue => e
          logger.warn "registration_script Redis write failed: #{e.message}"
        end
      end

      # Always write to local in-memory cache (fallback and fast path)
      self.class.registration_script_cache[key] = { body: result, at: Time.now }
      self.class.evict_key_mutex(key)
      result
    end
  end

  def read_registration_cache(cache_key)
    # Check Redis first — a hit here means another node already fetched the
    # script, so we serve it without going to Foreman and also warm the
    # local cache for subsequent requests to this node.
    if (redis = self.class.redis_client)
      begin
        cached = redis.get(cache_key)
        if cached
          logger.debug "registration_script cache=HIT source=redis key_prefix=#{cache_key[0, 40]}"
          self.class.registration_script_cache[cache_key] = { body: cached, at: Time.now }
          return cached
        end
      rescue => e
        logger.warn "registration_script Redis read failed, falling back to local cache: #{e.message}"
      end
    end

    # Fall back to per-node in-memory cache
    entry = self.class.registration_script_cache[cache_key]
    if entry && (Time.now - entry[:at]) < REGISTRATION_SCRIPT_CACHE_TTL
      logger.debug "registration_script cache=HIT source=local age=#{(Time.now - entry[:at]).to_i}s key_prefix=#{cache_key[0, 40]}"
      entry[:body]
    else
      logger.debug "registration_script cache=MISS key_prefix=#{cache_key[0, 40]}"
      nil
    end
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
