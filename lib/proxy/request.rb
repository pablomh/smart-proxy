require 'net/http'
require 'net/https'
require 'uri'
require 'cgi'

module Proxy::HttpRequest
  class ForemanRequestFactory
    def initialize(base_uri)
      @base_uri = base_uri
    end

    def query_string(input = {})
      Rack::Utils.build_nested_query(input.compact)
    end

    def create_get(path, query = {}, headers = {})
      uri = uri(path)
      req = Net::HTTP::Get.new("#{uri.path || '/'}?#{query_string(query)}")
      req = add_headers(req, headers)
      req
    end

    def uri(path)
      URI.join(@base_uri.to_s, path)
    end

    def add_headers(req, headers = {})
      req.add_field('Accept', 'application/json,version=2')
      req.content_type = headers.delete("Content-Type") || 'application/json'
      headers.each do |k, v|
        req.add_field(k, v)
      end
      req
    end

    def create_post(path, body, headers = {}, query = {})
      uri = uri(path)
      uri.query = query_string(query)
      req = Net::HTTP::Post.new(uri)
      req = add_headers(req, headers)
      req.body = body
      req
    end
  end

  class ForemanRequest
    DEFAULT_KEEP_ALIVE_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 200

    RETRY_EXCEPTIONS = [
      EOFError,
      Errno::ECONNRESET,
      Errno::EPIPE,
      IOError,
      Net::OpenTimeout,
      Net::ReadTimeout,
      OpenSSL::SSL::SSLError,
    ].freeze

    FOREMAN_MUTEX = Mutex.new
    REGISTRATION_GET_MUTEX = Mutex.new

    class << self
      def reset!
        FOREMAN_MUTEX.synchronize do
          finish_connection(:@foreman_http)
          ForemanRequest.instance_variable_set(:@connection_uri, nil)
        end
        REGISTRATION_GET_MUTEX.synchronize do
          finish_connection(:@registration_get_http)
        end
      end

      private

      def foreman_http
        ForemanRequest.instance_variable_get(:@foreman_http) ||
          ForemanRequest.instance_variable_set(:@foreman_http, http_init)
      end

      def registration_get_http
        ForemanRequest.instance_variable_get(:@registration_get_http) ||
          ForemanRequest.instance_variable_set(:@registration_get_http, http_init)
      end

      def finish_connection(ivar)
        old = ForemanRequest.instance_variable_get(ivar)
        ForemanRequest.instance_variable_set(ivar, nil)
        old&.finish
      rescue IOError, SystemCallError
        nil
      end

      def setting(name, default)
        value = Proxy::SETTINGS.respond_to?(name) ? Proxy::SETTINGS.public_send(name).to_i : 0
        (value > 0) ? value : default
      end

      def connection_uri
        ForemanRequest.instance_variable_get(:@connection_uri) ||
          ForemanRequest.instance_variable_set(:@connection_uri, URI.parse(Proxy::SETTINGS.foreman_url.to_s))
      end

      def http_init
        uri = connection_uri
        http             = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl     = uri.scheme == 'https'
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        http.keep_alive_timeout = setting(:foreman_keep_alive_timeout, DEFAULT_KEEP_ALIVE_TIMEOUT)
        http.read_timeout = setting(:foreman_request_timeout, DEFAULT_READ_TIMEOUT)
        timeout = setting(:foreman_connect_timeout, 0)
        http.open_timeout = timeout if timeout > 0

        if http.use_ssl?
          ca_file = Proxy::SETTINGS.foreman_ssl_ca || Proxy::SETTINGS.ssl_ca_file
          certificate = Proxy::SETTINGS.foreman_ssl_cert || Proxy::SETTINGS.ssl_certificate
          private_key = Proxy::SETTINGS.foreman_ssl_key || Proxy::SETTINGS.ssl_private_key

          if ca_file && !ca_file.to_s.empty?
            http.ca_file     = ca_file
            http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          end

          if certificate && !certificate.to_s.empty? && private_key && !private_key.to_s.empty?
            http.cert = OpenSSL::X509::Certificate.new(File.read(certificate))
            http.key  = OpenSSL::PKey.read(File.read(private_key), nil)
          end
        end

        http
      end
    end

    def send_request(request)
      execute_with(FOREMAN_MUTEX, :@foreman_http, request)
    end

    def send_request_direct(request)
      execute_with(REGISTRATION_GET_MUTEX, :@registration_get_http, request)
    end

    def request_factory
      ForemanRequestFactory.new(uri)
    end

    def uri
      @uri ||= URI.parse(Proxy::SETTINGS.foreman_url.to_s)
    end

    def http
      self.class.send(:foreman_http)
    end

    private

    def execute_with(mutex, ivar, request)
      mutex.synchronize do
        http = ForemanRequest.instance_variable_get(ivar) || ForemanRequest.instance_variable_set(ivar, self.class.send(:http_init))
        begin
          http.start unless http.started?
          http.request(request)
        rescue *RETRY_EXCEPTIONS
          begin
            http.finish
          rescue IOError, SystemCallError # rubocop:disable Lint/SuppressedException
          end
          ForemanRequest.instance_variable_set(ivar, self.class.send(:http_init))
          raise
        end
      end
    end
  end
end
