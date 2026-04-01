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
    # Clear class-level state between tests to prevent cross-test contamination
    Proxy::Registration::Api.registration_script_cache.clear
    Proxy::Registration::Api::KEY_MUTEXES.clear
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
end
