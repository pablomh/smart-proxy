require 'test_helper'
require 'uri'
require 'net/http'
require 'openssl'
require 'tempfile'
require 'mocha'
require 'templates/templates_plugin'
require 'templates/proxy_request'
require 'registration/proxy_request'
require "proxy/util"
require 'proxy/request'
require 'webmock/test_unit'

class RequestTest < Test::Unit::TestCase
  def setup
    @foreman_url = 'https://foreman.example.com'
    Proxy::SETTINGS.stubs(:foreman_url).returns(@foreman_url)
    Proxy::SETTINGS.stubs(:foreman_ssl_ca).returns(nil)
    Proxy::SETTINGS.stubs(:ssl_ca_file).returns(nil)
    Proxy::SETTINGS.stubs(:foreman_ssl_cert).returns(nil)
    Proxy::SETTINGS.stubs(:ssl_certificate).returns(nil)
    Proxy::SETTINGS.stubs(:foreman_ssl_key).returns(nil)
    Proxy::SETTINGS.stubs(:ssl_private_key).returns(nil)
    Proxy::SETTINGS.stubs(:foreman_request_timeout).returns(nil)
    Proxy::SETTINGS.stubs(:foreman_connect_timeout).returns(nil)
    Proxy::SETTINGS.stubs(:foreman_keep_alive_timeout).returns(nil)
    Proxy::HttpRequest::ForemanRequest.reset!
    @template_url = 'http://proxy.lan:8443'
    Proxy::Templates::Plugin.load_test_settings(:template_url => @template_url)
    @request = Proxy::HttpRequest::ForemanRequest.new
  end

  def test_get
    stub_request(:get, @foreman_url + '/path').to_return(:status => [200, 'OK'], :body => "body")
    proxy_req = @request.request_factory.create_get("/path")
    result = @request.send_request(proxy_req)
    assert_equal("body", result.body)
  end

  def test_get_with_headers
    stub_request(:get, @foreman_url + '/path?a=b').with(:headers => {"h1" => "header"}).to_return(:status => [200, 'OK'], :body => "body")
    proxy_req = @request.request_factory.create_get("/path", {"a" => "b"}, "h1" => "header")
    result = @request.send_request(proxy_req)
    assert_equal("body", result.body)
  end

  def test_get_with_nested_params
    stub_request(:get, @foreman_url + '/register?activation_keys%5B%5D=ac_AlmaLinux8&location_id=2&organization_id=1&repo_data%5B%5D%5Brepo%5D=repo1&repo_data%5B%5D%5Brepo_gpg_key_url%5D=key1&repo_data%5B%5D%5Brepo%5D=repo2&repo_data%5B%5D%5Brepo_gpg_key_url%5D=key2&update_packages=false')
      .with(:headers => {"h1" => "header"}).to_return(status: 200, body: "body", headers: {})
    request_params =
      { "activation_keys" => ["ac_AlmaLinux8"],
        "location_id" => "2",
        "organization_id" => "1",
        "repo_data" => [
          {"repo" => "repo1", "repo_gpg_key_url" => "key1"},
          {"repo" => "repo2", "repo_gpg_key_url" => "key2"},
        ],
        "update_packages" => "false" }
    proxy_req = @request.request_factory.create_get("/register", request_params, "h1" => "header")
    result = @request.send_request(proxy_req)
    assert_equal("body", result.body)
  end

  def test_post
    stub_request(:post, @foreman_url + '/path').with(:body => "body").to_return(:status => [200, 'OK'], :body => "body")
    proxy_req = @request.request_factory.create_post("/path", "body")
    result = @request.send_request(proxy_req)
    assert_equal("body", result.body)
  end

  def test_connection_is_shared_across_request_instances
    request_a = Proxy::HttpRequest::ForemanRequest.new
    request_b = Proxy::HttpRequest::ForemanRequest.new

    assert_same request_a.http, request_b.http
    assert_kind_of Net::HTTP, request_a.http
  end

  def test_connection_is_shared_across_foreman_request_subclasses
    registration_request = Proxy::Registration::ProxyRequest.new
    template_request = Proxy::Templates::ProxyRequest.new

    assert_same registration_request.http, template_request.http
  end

  def test_ssl_verify_none_when_no_ca_configured
    assert_equal OpenSSL::SSL::VERIFY_NONE, @request.http.verify_mode
  end

  def test_ssl_verify_peer_when_ca_configured
    ca_file = Tempfile.new(['foreman-ca', '.pem'])
    ca_file.write("ca-content")
    ca_file.flush

    Proxy::SETTINGS.stubs(:foreman_ssl_ca).returns(ca_file.path)
    Proxy::HttpRequest::ForemanRequest.reset!

    connection = Proxy::HttpRequest::ForemanRequest.new.http

    assert_equal OpenSSL::SSL::VERIFY_PEER, connection.verify_mode
    assert_equal ca_file.path, connection.ca_file
  ensure
    ca_file&.close
    ca_file&.unlink
  end

  def test_read_timeout_uses_default
    assert_equal 200, @request.http.read_timeout
  end

  def test_read_timeout_configurable
    Proxy::SETTINGS.stubs(:foreman_request_timeout).returns(120)
    Proxy::HttpRequest::ForemanRequest.reset!
    request = Proxy::HttpRequest::ForemanRequest.new
    assert_equal 120, request.http.read_timeout
  end

  def test_keep_alive_timeout_uses_default
    assert_equal 10, @request.http.keep_alive_timeout
  end

  def test_keep_alive_timeout_configurable
    Proxy::SETTINGS.stubs(:foreman_keep_alive_timeout).returns(8)
    Proxy::HttpRequest::ForemanRequest.reset!
    request = Proxy::HttpRequest::ForemanRequest.new
    assert_equal 8, request.http.keep_alive_timeout
  end

  def test_connect_timeout_not_set_by_default
    default = Net::HTTP.new('example.com').open_timeout
    assert_equal default, @request.http.open_timeout
  end

  def test_connect_timeout_configurable
    Proxy::SETTINGS.stubs(:foreman_connect_timeout).returns(30)
    Proxy::HttpRequest::ForemanRequest.reset!
    request = Proxy::HttpRequest::ForemanRequest.new
    assert_equal 30, request.http.open_timeout
  end

  def test_send_request_and_send_request_direct_use_different_connections
    stub_request(:get, @foreman_url + '/path').to_return(:status => [200, 'OK'], :body => "body")
    proxy_req = @request.request_factory.create_get("/path")

    @request.send_request(proxy_req)
    foreman_http = Proxy::HttpRequest::ForemanRequest.instance_variable_get(:@foreman_http)

    @request.send_request_direct(proxy_req)
    registration_get_http = Proxy::HttpRequest::ForemanRequest.instance_variable_get(:@registration_get_http)

    assert_not_same foreman_http, registration_get_http
  end

  def test_transport_error_replaces_connection_and_raises
    stub_request(:get, @foreman_url + '/path').to_raise(EOFError)
    proxy_req = @request.request_factory.create_get("/path")

    assert_raises(EOFError) { @request.send_request(proxy_req) }
    http_before = Proxy::HttpRequest::ForemanRequest.instance_variable_get(:@foreman_http)

    stub_request(:get, @foreman_url + '/path').to_raise(EOFError)
    assert_raises(EOFError) { @request.send_request(proxy_req) }

    http_after = Proxy::HttpRequest::ForemanRequest.instance_variable_get(:@foreman_http)
    assert_not_same http_before, http_after
  end

  def test_send_request_direct_succeeds
    stub_request(:get, @foreman_url + '/path').to_return(:status => [200, 'OK'], :body => "body")
    proxy_req = @request.request_factory.create_get("/path")
    result = @request.send_request_direct(proxy_req)
    assert_equal("body", result.body)
  end

  def test_post_with_nested_params
    stub_request(:post, @foreman_url + '/register?activation_keys%5B%5D=ac_AlmaLinux8&location_id=2&organization_id=1&repo_data%5B%5D%5Brepo%5D=repo1&repo_data%5B%5D%5Brepo_gpg_key_url%5D=key1&repo_data%5B%5D%5Brepo%5D=repo2&repo_data%5B%5D%5Brepo_gpg_key_url%5D=key2&update_packages=false')
      .to_return(status: 200, body: "body", headers: {h1: "header"})
    request_params =
      { "activation_keys" => ["ac_AlmaLinux8"],
        "location_id" => "2",
        "organization_id" => "1",
        "repo_data" => [
          {"repo" => "repo1", "repo_gpg_key_url" => "key1"},
          {"repo" => "repo2", "repo_gpg_key_url" => "key2"},
        ],
        "update_packages" => "false" }
    proxy_req = @request.request_factory.create_post "/register", {"body" => "body"}, {"h1" => "header"}, request_params
    result = @request.send_request(proxy_req)
    assert_equal("body", result.body)
  end
end
