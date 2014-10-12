require 'digest/md5'
require 'active_support/core_ext/module/delegation'

module ActionDispatch # :nodoc:
  # Represents an HTTP response generated by a controller action. One can use
  # an ActionDispatch::Response object to retrieve the current state
  # of the response, or customize the response. An Response object can
  # either represent a "real" HTTP response (i.e. one that is meant to be sent
  # back to the web browser) or a test response (i.e. one that is generated
  # from integration tests). See CgiResponse and TestResponse, respectively.
  #
  # Response is mostly a Ruby on Rails framework implement detail, and
  # should never be used directly in controllers. Controllers should use the
  # methods defined in ActionController::Base instead. For example, if you want
  # to set the HTTP response's content MIME type, then use
  # ActionControllerBase#headers instead of Response#headers.
  #
  # Nevertheless, integration tests may want to inspect controller responses in
  # more detail, and that's when Response can be useful for application
  # developers. Integration test methods such as
  # ActionDispatch::Integration::Session#get and
  # ActionDispatch::Integration::Session#post return objects of type
  # TestResponse (which are of course also of type Response).
  #
  # For example, the following demo integration "test" prints the body of the
  # controller response to the console:
  #
  #  class DemoControllerTest < ActionDispatch::IntegrationTest
  #    def test_print_root_path_to_console
  #      get('/')
  #      puts @response.body
  #    end
  #  end
  class Response < Rack::Response
    attr_accessor :request, :blank

    attr_writer :header, :sending_file
    alias_method :headers=, :header=

    module Setup
      def initialize(status = 200, header = {}, body = [])
        @writer = lambda { |x| @body << x }
        @block = nil
        @length = 0

        @status, @header, @body = status, header, body

        @cookie = []
        @sending_file = false

        @blank = false

        if content_type = self["Content-Type"]
          type, charset = content_type.split(/;\s*charset=/)
          @content_type = Mime::Type.lookup(type)
          @charset = charset || "UTF-8"
        end

        yield self if block_given?
      end
    end

    include Setup
    include ActionDispatch::Http::Cache::Response

    def status=(status)
      @status = Rack::Utils.status_code(status)
    end

    # The response code of the request
    def response_code
      @status
    end

    # Returns a String to ensure compatibility with Net::HTTPResponse
    def code
      @status.to_s
    end

    def message
      Rack::Utils::HTTP_STATUS_CODES[@status]
    end
    alias_method :status_message, :message

    def respond_to?(method)
      if method.to_sym == :to_path
        @body.respond_to?(:to_path)
      else
        super
      end
    end

    def to_path
      @body.to_path
    end

    def body
      str = ''
      each { |part| str << part.to_s }
      str
    end

    EMPTY = " "

    def body=(body)
      @blank = true if body == EMPTY
      @body = body.respond_to?(:to_str) ? [body] : body
    end

    def body_parts
      @body
    end

    def location
      headers['Location']
    end
    alias_method :redirect_url, :location

    def location=(url)
      headers['Location'] = url
    end

    # Sets the HTTP response's content MIME type. For example, in the controller
    # you could write this:
    #
    #  response.content_type = "text/plain"
    #
    # If a character set has been defined for this response (see charset=) then
    # the character set information will also be included in the content type
    # information.
    attr_accessor :charset, :content_type

    CONTENT_TYPE    = "Content-Type"

    cattr_accessor(:default_charset) { "utf-8" }

    def to_a
      assign_default_content_type_and_charset!
      handle_conditional_get!
      self["Set-Cookie"] = @cookie.join("\n") unless @cookie.blank?
      self["ETag"]       = @_etag if @_etag
      super
    end

    alias prepare! to_a

    def each(&callback)
      if @body.respond_to?(:call)
        @writer = lambda { |x| callback.call(x) }
        @body.call(self, self)
      else
        @body.each { |part| callback.call(part.to_s) }
      end

      @writer = callback
      @block.call(self) if @block
    end

    def write(str)
      str = str.to_s
      @writer.call str
      str
    end

    # Returns the response cookies, converted to a Hash of (name => value) pairs
    #
    #   assert_equal 'AuthorOfNewPage', r.cookies['author']
    def cookies
      cookies = {}
      if header = @cookie
        header = header.split("\n") if header.respond_to?(:to_str)
        header.each do |cookie|
          if pair = cookie.split(';').first
            key, value = pair.split("=").map { |v| Rack::Utils.unescape(v) }
            cookies[key] = value
          end
        end
      end
      cookies
    end

    def set_cookie(key, value)
      case value
      when Hash
        domain  = "; domain="  + value[:domain]    if value[:domain]
        path    = "; path="    + value[:path]      if value[:path]
        # According to RFC 2109, we need dashes here.
        # N.B.: cgi.rb uses spaces...
        expires = "; expires=" + value[:expires].clone.gmtime.
          strftime("%a, %d-%b-%Y %H:%M:%S GMT")    if value[:expires]
        secure = "; secure"  if value[:secure]
        httponly = "; HttpOnly" if value[:httponly]
        value = value[:value]
      end
      value = [value]  unless Array === value
      cookie = Rack::Utils.escape(key) + "=" +
        value.map { |v| Rack::Utils.escape v }.join("&") +
        "#{domain}#{path}#{expires}#{secure}#{httponly}"

      @cookie << cookie
    end

    def delete_cookie(key, value={})
      @cookie.reject! { |cookie|
        cookie =~ /\A#{Rack::Utils.escape(key)}=/
      }

      set_cookie(key,
                 {:value => '', :path => nil, :domain => nil,
                   :expires => Time.at(0) }.merge(value))
    end

    private
      def assign_default_content_type_and_charset!
        return if headers[CONTENT_TYPE].present?

        @content_type ||= Mime::HTML
        @charset      ||= self.class.default_charset

        type = @content_type.to_s.dup
        type << "; charset=#{@charset}" unless @sending_file

        headers[CONTENT_TYPE] = type
      end

  end
end
