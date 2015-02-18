# -*- coding: utf-8 -*-
require 'rubygems'
require 'nokogiri'
require 'time'
require 'handsoap/xml_mason'

# Nokogiri doesn't have a way of getting plain strings out,
# so this monkeypatch adds that capability ..
module Utf8StringPatch
  def to_utf8
    # HTMLEntities.decode_entities(self.serialize(:encoding => 'UTF-8'))
    if Gem.loaded_specs['nokogiri'].version >= Gem::Version.new('1.3.0')
      self.serialize(:encoding => 'UTF-8').gsub('&lt;', '<').gsub('&gt;', '>').gsub('&quot;', '"').gsub('&apos;', "'").gsub('&amp;', '&')
    else
      self.serialize('UTF-8').gsub('&lt;', '<').gsub('&gt;', '>').gsub('&quot;', '"').gsub('&apos;', "'").gsub('&amp;', '&')
    end
  end
end

module Nokogiri
  module XML
    class Text
      include Utf8StringPatch
    end
    class Nodeset
      include Utf8StringPatch
    end
    class Attr
      include Utf8StringPatch
    end
  end
end

module Handsoap

  def self.http_driver
    @http_driver || (self.http_driver = :curb)
  end

  def self.http_driver=(driver)
    @http_driver = driver
    require 'httpclient' if driver == :httpclient
    require 'curb' if driver == :curb
    return driver
  end

  SOAP_NAMESPACE = { 1 => 'http://schemas.xmlsoap.org/soap/envelope/', 2 => 'http://www.w3.org/2001/12/soap-encoding' }

  class Response
    def initialize(http_body, soap_namespace)
      @http_body = http_body
      @soap_namespace = soap_namespace
      @document = :lazy
      @fault = :lazy
    end
    def document?
      !! document
    end
    def document
      if @document == :lazy
        doc = Nokogiri::XML(@http_body)
        @document = (doc && doc.root && doc.errors.empty?) ? doc : nil
      end
      return @document
    end
    def fault?
      !! fault
    end
    def fault
      if @fault == :lazy
        nodes = document? ? document.xpath('/env:Envelope/env:Body/descendant-or-self::env:Fault', { 'env' => @soap_namespace }) : []
        @fault = nodes.any? ? Fault.from_xml(nodes.first, :namespace => @soap_namespace) : nil
      end
      return @fault
    end
  end

  class Fault < Exception
    attr_reader :code, :reason, :details
    def initialize(code, reason, details)
      @code = code
      @reason = reason
      @details = details
    end
    def to_s
      "Handsoap::Fault { :code => '#{@code}', :reason => '#{@reason}' }"
    end
    def self.from_xml(node, options = { :namespace => nil })
      if not options[:namespace]
        raise "Missing option :namespace"
      end
      ns = { 'env' => options[:namespace] }
      fault_code = node.xpath('./env:Code/env:Value/text()', ns).to_s
      if fault_code == ""
        fault_code = node.xpath('./faultcode/text()', ns).to_s
      end
      reason = node.xpath('./env:Reason/env:Text[1]/text()', ns).to_s
      if reason == ""
        reason = node.xpath('./faultstring/text()', ns).to_s
      end
      details = node.xpath('./detail/*', ns)
      self.new(fault_code, reason, details)
    end
  end

  class Service
    @@logger = nil
    def self.logger=(io)
      @@logger = io
    end
    def self.endpoint(args = {})
      @protocol_version = args[:version] || raise("Missing option :version")
      @uri = args[:uri] || raise("Missing option :uri")
    end
    def self.envelope_namespace
      if SOAP_NAMESPACE[@protocol_version].nil?
        raise "Unknown protocol version '#{@protocol_version.inspect}'"
      end
      SOAP_NAMESPACE[@protocol_version]
    end
    def self.request_content_type
      @protocol_version == 1 ? "text/xml" : "application/soap+xml"
    end
    def self.map_method(mapping)
      if @mapping.nil?
        @mapping = {}
      end
      @mapping.merge! mapping
    end
    def self.on_create_document(&block)
      @create_document_callback = block
    end
    def self.fire_on_create_document(doc)
      if @create_document_callback
        @create_document_callback.call doc
      end
    end
    def self.uri
      @uri
    end
    def self.get_mapping(name)
      @mapping[name] if @mapping
    end
    @@instance = {}
    def self.instance
      @@instance[self.to_s] ||= self.new
    end
    def self.method_missing(method, *args)
      if instance.respond_to?(method)
        instance.__send__ method, *args
      else
        super
      end
    end
    def method_missing(method, *args)
      action = self.class.get_mapping(method)
      if action
        invoke(action, *args)
      else
        super
      end
    end
    def invoke(action, options = { :soap_action => :auto }, &block)
      if action
        if options.kind_of? String
          options = { :soap_action => options }
        end
        if options[:soap_action] == :auto
          options[:soap_action] = action.gsub(/^.+:/, "")
        elsif options[:soap_action] == :none
          options[:soap_action] = nil
        end
        doc = make_envelope do |body|
          body.add action
        end
        if block_given?
          yield doc.find(action)
        end
        dispatch(doc, options[:soap_action])
      end
    end
    def on_before_dispatch
    end
    def on_fault(fault)
      raise fault
    end
    private
    # Helper to serialize a node into a ruby string
    def xml_to_str(node, xquery = nil)
      n = xquery ? node.xpath(xquery, ns).first : node
      return if n.nil?
      n.to_utf8
    end
    alias_method :xml_to_s, :xml_to_str
    # Helper to serialize a node into a ruby integer
    def xml_to_int(node, xquery = nil)
      n = xquery ? node.xpath(xquery, ns).first : node
      return if n.nil?
      n.to_s.to_i
    end
    alias_method :xml_to_i, :xml_to_int
    # Helper to serialize a node into a ruby float
    def xml_to_float(node, xquery = nil)
      n = xquery ? node.xpath(xquery, ns).first : node
      return if n.nil?
      n.to_s.to_f
    end
    alias_method :xml_to_f, :xml_to_float
    # Helper to serialize a node into a ruby boolean
    def xml_to_bool(node, xquery = nil)
      n = xquery ? node.xpath(xquery, ns).first : node
      return if n.nil?
      n.to_s == "true"
    end
    # Helper to serialize a node into a ruby Time object
    def xml_to_date(node, xquery = nil)
      n = xquery ? node.xpath(xquery, ns).first : node
      return if n.nil?
      Time.iso8601(n.to_s)
    end
    def debug(message = nil)
      if @@logger
        if message
          @@logger.puts(message)
        end
        if block_given?
          yield @@logger
        end
      end
    end
    def dispatch(doc, action)
      on_before_dispatch()
      headers = {
        "Content-Type" => "#{self.class.request_content_type};charset=UTF-8"
      }
      headers["SOAPAction"] = action unless action.nil?
      body = doc.to_s
      debug do |logger|
        logger.puts "==============="
        logger.puts "--- Request ---"
        logger.puts "URI: %s" % [self.class.uri]
        logger.puts headers.map { |key,value| key + ": " + value }.join("\n")
        logger.puts "---"
        logger.puts body
      end
      if Handsoap.http_driver == :curb
        http_client = Curl::Easy.new(self.class.uri)
        warn 'Warning: Centic hotfix - disables ssl verify'
        http_client.ssl_verify_peer = false
        http_client.headers = headers
        http_client.http_post body
        debug do |logger|
          logger.puts "--- Response ---"
          logger.puts "HTTP Status: %s" % [http_client.response_code]
          logger.puts "Content-Type: %s" % [http_client.content_type]
          logger.puts "---"
          logger.puts Handsoap.pretty_format_envelope(http_client.body_str)
        end
        soap_response = Response.new(http_client.body_str, self.class.envelope_namespace)
      elsif Handsoap.http_driver == :httpclient
        response = HTTPClient.new.post(self.class.uri, body, headers)
        debug do |logger|
          logger.puts "--- Response ---"
          logger.puts "HTTP Status: %s" % [response.status]
          logger.puts "Content-Type: %s" % [response.contenttype]
          logger.puts "---"
          logger.puts Handsoap.pretty_format_envelope(response.content)
        end
        soap_response = Response.new(response.content, self.class.envelope_namespace)
      else
        raise "Unknown http driver #{Handsoap.http_driver}"
      end
      if soap_response.fault?
        return self.on_fault(soap_response.fault)
      end
      return soap_response
    end
    def make_envelope
      doc = XmlMason::Document.new do |doc|
        doc.alias 'env', self.class.envelope_namespace
        doc.add "env:Envelope" do |env|
          env.add "*:Header"
          env.add "*:Body"
        end
      end
      self.class.fire_on_create_document doc
      if block_given?
        yield doc.find("Body")
      end
      return doc
    end
  end

  def self.pretty_format_envelope(xml_string)
    if /^<.*:Envelope/.match(xml_string)
      begin
        doc = Nokogiri::XML(xml_string)
      rescue Exception => ex
        return "Formatting failed: " + ex.to_s
      end
      return doc.to_s
      # return "\n\e[1;33m" + doc.to_s + "\e[0m"
    end
    return xml_string
  end

end
