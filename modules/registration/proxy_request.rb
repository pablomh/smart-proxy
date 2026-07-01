require 'proxy/request'

module Proxy::Registration
  class ProxyRequest < ::Proxy::HttpRequest::ForemanRequest
    def global_register(request)
      proxy_req = request_factory.create_get '/register',
                                             request_params(request),
                                             headers(request)

      send_request_direct(proxy_req)
    end

    # Retries once on transport errors. Foreman's POST /register uses
    # find_or_initialize_by for the host record, making a single replay
    # safe after a stale keep-alive connection failure.
    REGISTER_RETRY_EXCEPTIONS = [
      EOFError,
      Errno::ECONNRESET,
      Errno::EPIPE,
      IOError,
      OpenSSL::SSL::SSLError,
    ].freeze

    def host_register(request)
      body = request.body.read
      hdrs = headers(request)

      if request.content_type == 'application/x-www-form-urlencoded'
        content_type = request.content_type
        query = { url: register_url(request) }
        build_req = -> { request_factory.create_post('/register', body, hdrs.merge("Content-Type" => content_type), query) }
      else
        params = request_params(request)
        build_req = -> { request_factory.create_post('/register', body, hdrs, params) }
      end

      retried = false
      begin
        send_request(build_req.call)
      rescue *REGISTER_RETRY_EXCEPTIONS
        raise if retried
        retried = true
        retry
      end
    end

    private

    def request_params(request)
      params = request.params
      params[:url] = register_url(request)
      params
    end

    def register_url(request)
      Proxy::Registration::Plugin.settings.registration_url || request.env['REQUEST_URI']&.split('/register')&.first
    end

    def headers(request)
      Hash[request.env.select { |k, v| k =~ /^HTTP_/ && k !~ /^HTTP_(VERSION|HOST)$/ }.map { |k, v| [k[5..], v] }]
    rescue Exception => e
      logger.warn "Unable to extract request headers: #{e}"
      {}
    end
  end
end
