require 'test_helper'
require 'registration/registration_api'

class RegistrationRegisterApiTest < Test::Unit::TestCase
  include Rack::Test::Methods

  def app
    Proxy::Registration::Api.new
  end

  def setup
    @foreman_url = 'http://foreman.example.com'
    Proxy::SETTINGS.stubs(:foreman_url).returns(@foreman_url)
    Proxy::Registration::Plugin.settings.stubs(:max_concurrent_registrations).returns(nil)
    Proxy::Registration::Plugin.settings.stubs(:cache_url).returns(nil)
    # Clear class-level state between tests to prevent cross-test contamination
    Proxy::Registration::Api.registration_script_cache.clear
    Proxy::Registration::Api::KEY_MUTEXES.clear
    Proxy::Registration::Api.instance_variable_set(:@registration_semaphore, nil)
    Proxy::Registration::Api.instance_variable_set(:@registration_cache_client, nil)
  end

  def test_global_register_template
    stub_request(:get, "#{@foreman_url}/register").to_return(body: 'template')

    get "/"
    assert last_response.ok?
    assert_match('template', last_response.body)
  end

  def test_global_register_template_with_args
    stub_request(:get, "#{@foreman_url}/register?param=test").to_return(body: 'template')

    get '/', { param: 'test' }
    assert last_response.ok?
    assert_match('template', last_response.body)
  end

  def test_host_register_template
    stub_request(:post, "#{@foreman_url}/register").to_return(body: 'template')

    post '/'
    assert last_response.ok?
    assert_match('template', last_response.body)
  end

  def test_host_register_template_with_args
    stub_request(:post, "#{@foreman_url}/register").to_return(body: 'template')

    post '/', { host: { name: 'test.example.com', build: false } }
    assert last_response.ok?
    assert_match('template', last_response.body)
  end

  def test_host_register_template_with_args_using_json
    stub_request(:post, "#{@foreman_url}/register").to_return(body: 'template')

    post '/', { host: { name: 'test.example.com', build: false } }, { 'CONTENT_TYPE' => 'application/json' }
    assert last_response.ok?
    assert_match('template', last_response.body)
  end

  def test_host_register_template_with_array_args
    stub_request(:post, "#{@foreman_url}/register").to_return(body: 'template')

    post '/', { host: { name: 'test.example.com', build: false, repo_data: [{repo: 'repo1', repo_gpg_key_url: 'url1'}, {repo: 'repo2', repo_gpg_key_url: 'url2'}] } }, { 'CONTENT_TYPE' => 'application/json' }
    assert last_response.ok?
    assert_match('template', last_response.body)
  end

  def test_global_401
    stub_request(:get, "#{@foreman_url}/register").to_return(body: '401', status: 401, headers: { "Content-Type" => 'text/plain; charset=UTF-8' })

    get '/'
    assert last_response.unauthorized?
    assert_match('401', last_response.body)
  end

  def test_host_401
    stub_request(:post, "#{@foreman_url}/register").to_return(body: '401', status: 401, headers: { "Content-Type" => 'text/plain; charset=UTF-8' })

    post '/'
    assert last_response.unauthorized?
    assert_match('401', last_response.body)
  end

  def test_global_401_html_response
    stub_request(:get, "#{@foreman_url}/register").to_return(body: '401', status: 401, headers: { "Content-Type" => 'text/html; charset=UTF-8' })

    get '/'
    assert last_response.unauthorized?
    assert_match("echo \"Internal Server Error\"\nexit 1\n", last_response.body)
  end

  def test_host_401_html_response
    stub_request(:post, "#{@foreman_url}/register").to_return(body: '401', status: 401, headers: { "Content-Type" => 'text/html; charset=UTF-8' })

    post '/'
    assert last_response.unauthorized?
    assert_match("echo \"Internal Server Error\"\nexit 1\n", last_response.body)
  end

  def test_global_500
    Rack::NullLogger.any_instance.stubs(:exception)
    stub_request(:get, "#{@foreman_url}/register").to_timeout

    get '/'
    assert last_response.server_error?
    assert_match("echo \"Internal Server Error\"\nexit 1\n", last_response.body)
  end

  def test_global_register_caches_response
    stub = stub_request(:get, "#{@foreman_url}/register").to_return(body: 'template')

    2.times do
      get '/'
      assert last_response.ok?
      assert_match('template', last_response.body)
    end

    assert_requested stub, times: 1
  end

  def test_global_register_cache_key_is_parameter_order_independent
    # Cache key is normalised (params sorted alphabetically), so both orderings
    # produce activation_keys=rhel9&owner=Default_Organization and share one entry.
    stub_request(:get, "#{@foreman_url}/register?activation_keys=rhel9&owner=Default_Organization")
      .to_return(body: 'template')

    get '/', { owner: 'Default_Organization', activation_keys: 'rhel9' }
    assert last_response.ok?

    # Different parameter order — must hit cache, not Foreman again
    get '/', { activation_keys: 'rhel9', owner: 'Default_Organization' }
    assert last_response.ok?

    assert_requested :get, "#{@foreman_url}/register?activation_keys=rhel9&owner=Default_Organization", times: 1
  end

  def test_global_register_caches_per_key
    stub_a = stub_request(:get, "#{@foreman_url}/register?key=a").to_return(body: 'template_a')
    stub_b = stub_request(:get, "#{@foreman_url}/register?key=b").to_return(body: 'template_b')

    get '/', { key: 'a' }
    assert_match('template_a', last_response.body)
    get '/', { key: 'b' }
    assert_match('template_b', last_response.body)
    # second requests — must be served from cache
    get '/', { key: 'a' }
    assert_match('template_a', last_response.body)
    get '/', { key: 'b' }
    assert_match('template_b', last_response.body)

    assert_requested stub_a, times: 1
    assert_requested stub_b, times: 1
  end

  def test_global_register_evicts_mutex_after_caching
    stub_request(:get, "#{@foreman_url}/register").to_return(body: 'template')

    get '/'
    assert last_response.ok?
    assert_empty Proxy::Registration::Api::KEY_MUTEXES
  end

  def test_global_register_cache_entry_expires_after_ttl
    Proxy::Registration::Api.registration_script_cache[''] = {
      body: 'stale-template',
      at: Time.now - Proxy::Registration::Api::REGISTRATION_SCRIPT_CACHE_TTL - 1,
    }
    stub = stub_request(:get, "#{@foreman_url}/register").to_return(body: 'fresh-template')

    get '/'
    assert last_response.ok?
    assert_match('fresh-template', last_response.body)
    assert_requested stub, times: 1
  end

  def test_global_register_does_not_cache_errors
    stub = stub_request(:get, "#{@foreman_url}/register").to_return(
      body: 'error', status: 500, headers: { "Content-Type" => 'text/plain' }
    )

    2.times do
      get '/'
      assert last_response.server_error?
    end

    assert_requested stub, times: 2
  end

  def test_host_500
    Rack::NullLogger.any_instance.stubs(:exception)
    stub_request(:post, "#{@foreman_url}/register").to_timeout

    post '/'
    assert last_response.server_error?
    assert_match("echo \"Internal Server Error\"\nexit 1\n", last_response.body)
  end

  # ---------------------------------------------------------------------------
  # GET /health
  # ---------------------------------------------------------------------------

  def test_health_returns_ok_when_foreman_reachable
    Proxy::Registration::ProxyRequest.any_instance.stubs(:foreman_reachable?).returns(true)

    get '/health'
    assert last_response.ok?
    assert_equal 'application/json', last_response.content_type
    assert_match('"status":"ok"', last_response.body)
  end

  def test_health_returns_503_when_foreman_unreachable
    Proxy::Registration::ProxyRequest.any_instance.stubs(:foreman_reachable?).returns(false)

    get '/health'
    assert_equal 503, last_response.status
    assert_match('"status":"error"', last_response.body)
  end

  def test_health_returns_503_on_unexpected_error
    Rack::NullLogger.any_instance.stubs(:exception)
    Proxy::Registration::ProxyRequest.any_instance.stubs(:foreman_reachable?).raises(StandardError, 'boom')

    get '/health'
    assert_equal 503, last_response.status
    assert_match('"status":"error"', last_response.body)
  end

  # ---------------------------------------------------------------------------
  # Concurrency limiter (:max_concurrent_registrations)
  # ---------------------------------------------------------------------------

  def test_host_register_proceeds_when_within_limit
    Proxy::Registration::Plugin.settings.stubs(:max_concurrent_registrations).returns(2)
    stub_request(:post, "#{@foreman_url}/register").to_return(body: 'template')

    post '/'
    assert last_response.ok?
    assert_match('template', last_response.body)
  end

  def test_host_register_returns_503_when_limit_exhausted
    Proxy::Registration::Plugin.settings.stubs(:max_concurrent_registrations).returns(1)
    # Exhaust the one available permit before the request arrives
    Proxy::Registration::Api.registration_semaphore.try_acquire

    post '/'
    assert_equal 503, last_response.status
    assert_equal '30', last_response.headers['Retry-After']
    assert_match('retry', last_response.body)
  end

  def test_host_register_releases_permit_after_success
    Proxy::Registration::Plugin.settings.stubs(:max_concurrent_registrations).returns(1)
    stub_request(:post, "#{@foreman_url}/register").to_return(body: 'template')

    post '/'
    assert last_response.ok?
    # Permit must be released — a second request should also succeed
    post '/'
    assert last_response.ok?
  end

  def test_host_register_releases_permit_after_error
    Rack::NullLogger.any_instance.stubs(:exception)
    Proxy::Registration::Plugin.settings.stubs(:max_concurrent_registrations).returns(1)
    stub_request(:post, "#{@foreman_url}/register").to_timeout

    post '/'
    assert last_response.server_error?
    # with_concurrency_limit's ensure block must release permit even on error
    assert_equal 1, Proxy::Registration::Api.registration_semaphore.available_permits
  end

  def test_host_register_unlimited_when_setting_absent
    # Default (nil) means no semaphore — unlimited concurrency
    assert_nil Proxy::Registration::Api.registration_semaphore
    stub_request(:post, "#{@foreman_url}/register").to_return(body: 'template')

    post '/'
    assert last_response.ok?
  end

  # ---------------------------------------------------------------------------
  # Shared Redis cache (:cache_url)
  # ---------------------------------------------------------------------------

  def test_global_register_serves_from_shared_cache_on_hit
    redis = mock('redis')
    redis.stubs(:get).returns('cached-template')
    Proxy::Registration::Api.instance_variable_set(:@registration_cache_client, redis)
    stub = stub_request(:get, "#{@foreman_url}/register").to_return(body: 'fresh')

    get '/'
    assert last_response.ok?
    assert_match('cached-template', last_response.body)
    assert_not_requested stub
  end

  def test_global_register_writes_to_shared_cache_on_miss
    redis = mock('redis')
    redis.stubs(:get).returns(nil)
    redis.expects(:setex).with(anything, Proxy::Registration::Api::REGISTRATION_SCRIPT_CACHE_TTL, 'template')
    Proxy::Registration::Api.instance_variable_set(:@registration_cache_client, redis)
    stub_request(:get, "#{@foreman_url}/register").to_return(body: 'template')

    get '/'
    assert last_response.ok?
    assert_match('template', last_response.body)
  end

  def test_global_register_falls_back_to_local_cache_on_redis_read_error
    Rack::NullLogger.any_instance.stubs(:warn)
    redis = mock('redis')
    redis.stubs(:get).raises(StandardError, 'connection refused')
    Proxy::Registration::Api.instance_variable_set(:@registration_cache_client, redis)
    stub_request(:get, "#{@foreman_url}/register").to_return(body: 'template')

    get '/'
    assert last_response.ok?
    assert_match('template', last_response.body)
  end

  def test_global_register_continues_on_redis_write_error
    Rack::NullLogger.any_instance.stubs(:warn)
    redis = mock('redis')
    redis.stubs(:get).returns(nil)
    redis.stubs(:setex).raises(StandardError, 'write error')
    Proxy::Registration::Api.instance_variable_set(:@registration_cache_client, redis)
    stub_request(:get, "#{@foreman_url}/register").to_return(body: 'template')

    get '/'
    assert last_response.ok?
    assert_match('template', last_response.body)
    # Local cache must still be populated as fallback
    assert_not_nil Proxy::Registration::Api.registration_script_cache['']
  end
end
