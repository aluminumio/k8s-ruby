# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'webrick'
require 'thread'

# Disable WebMock for integration tests - we need real connections
WebMock.allow_net_connect!

# Minimal SOCKS5 proxy server for testing (RFC 1928)
class TestSOCKS5Proxy
  SOCKS5_VERSION = 0x05
  SOCKS5_NO_AUTH = 0x00
  SOCKS5_AUTH_USER_PASS = 0x02
  SOCKS5_CMD_CONNECT = 0x01
  SOCKS5_ATYP_IPV4 = 0x01
  SOCKS5_ATYP_DOMAIN = 0x03
  SOCKS5_SUCCESS = 0x00

  attr_reader :port, :connections

  def initialize(port: 0, require_auth: false, username: nil, password: nil)
    @server = TCPServer.new('127.0.0.1', port)
    @port = @server.addr[1]
    @running = false
    @connections = []
    @require_auth = require_auth
    @username = username
    @password = password
  end

  def start
    @running = true
    @thread = Thread.new do
      while @running
        begin
          client = @server.accept_nonblock
          Thread.new(client) { |c| handle_client(c) }
        rescue IO::WaitReadable
          IO.select([@server], nil, nil, 0.1)
        rescue => e
          break unless @running
        end
      end
    end
  end

  def stop
    @running = false
    @thread&.join(2)
    @server&.close rescue nil
  end

  private

  def handle_client(client)
    # Read greeting
    version, nmethods = client.read(2).unpack('CC')
    return client.close unless version == SOCKS5_VERSION

    methods = client.read(nmethods).unpack('C*')

    # Choose auth method
    if @require_auth
      if methods.include?(SOCKS5_AUTH_USER_PASS)
        client.write([SOCKS5_VERSION, SOCKS5_AUTH_USER_PASS].pack('CC'))
        return client.close unless authenticate(client)
      else
        client.write([SOCKS5_VERSION, 0xFF].pack('CC'))
        return client.close
      end
    else
      client.write([SOCKS5_VERSION, SOCKS5_NO_AUTH].pack('CC'))
    end

    # Read connect request
    version, cmd, _, atyp = client.read(4).unpack('CCCC')
    return client.close unless version == SOCKS5_VERSION && cmd == SOCKS5_CMD_CONNECT

    # Parse destination
    dest_host, dest_port = case atyp
    when SOCKS5_ATYP_IPV4
      addr = client.read(4).unpack('CCCC').join('.')
      port = client.read(2).unpack('n').first
      [addr, port]
    when SOCKS5_ATYP_DOMAIN
      len = client.read(1).unpack('C').first
      host = client.read(len)
      port = client.read(2).unpack('n').first
      [host, port]
    else
      return client.close
    end

    @connections << { host: dest_host, port: dest_port }

    # Connect to target
    begin
      target = TCPSocket.new(dest_host, dest_port)
    rescue => e
      # Connection refused
      client.write([SOCKS5_VERSION, 0x05, 0x00, SOCKS5_ATYP_IPV4, 0, 0, 0, 0, 0, 0].pack('CCCCCCCCCC'))
      return client.close
    end

    # Send success response
    client.write([SOCKS5_VERSION, SOCKS5_SUCCESS, 0x00, SOCKS5_ATYP_IPV4, 127, 0, 0, 1, 0, 0].pack('CCCCCCCCCC'))

    # Relay data
    relay(client, target)
  ensure
    client&.close rescue nil
    target&.close rescue nil
  end

  def authenticate(client)
    version = client.read(1).unpack('C').first
    return false unless version == 0x01

    ulen = client.read(1).unpack('C').first
    username = client.read(ulen)
    plen = client.read(1).unpack('C').first
    password = client.read(plen)

    if username == @username && password == @password
      client.write([0x01, 0x00].pack('CC'))
      true
    else
      client.write([0x01, 0x01].pack('CC'))
      false
    end
  end

  def relay(client, target)
    loop do
      readable, = IO.select([client, target], nil, nil, 5)
      break if readable.nil?

      readable.each do |sock|
        begin
          data = sock.read_nonblock(4096)
          if sock == client
            target.write(data)
          else
            client.write(data)
          end
        rescue IO::WaitReadable
          next
        rescue EOFError, Errno::ECONNRESET
          return
        end
      end
    end
  end
end

# Simple HTTP server for testing
class TestHTTPServer
  attr_reader :port, :requests

  def initialize(port: 0)
    @requests = []
    @server = WEBrick::HTTPServer.new(
      Port: port,
      Logger: WEBrick::Log.new("/dev/null"),
      AccessLog: []
    )
    @port = @server.config[:Port]

    @server.mount_proc '/api/v1' do |req, res|
      @requests << req.path
      res.content_type = 'application/json'
      res.body = '{"kind":"APIResourceList","apiVersion":"v1","resources":[]}'
    end

    @server.mount_proc '/version' do |req, res|
      @requests << req.path
      res.content_type = 'application/json'
      res.body = '{"major":"1","minor":"28","gitVersion":"v1.28.0"}'
    end
  end

  def start
    @thread = Thread.new { @server.start }
    sleep 0.1 # Give server time to start
  end

  def stop
    @server.shutdown
    @thread&.join(2)
  end
end

RSpec.describe 'SOCKS5 Proxy Integration', :integration do
  let(:http_server) { TestHTTPServer.new }
  let(:socks_proxy) { TestSOCKS5Proxy.new }

  before do
    http_server.start
    socks_proxy.start
  end

  after do
    socks_proxy.stop
    http_server.stop
  end

  describe 'HTTP request through SOCKS5 proxy' do
    it 'successfully connects through the proxy' do
      transport = K8s::Transport.new(
        "http://127.0.0.1:#{http_server.port}",
        socks5_proxy: "127.0.0.1:#{socks_proxy.port}"
      )

      result = transport.get('/api/v1')

      expect(result).to be_a(Hash)
      expect(result['kind']).to eq('APIResourceList')
      expect(socks_proxy.connections).to include(
        hash_including(host: '127.0.0.1', port: http_server.port)
      )
    end

    it 'records all requests through the proxy' do
      transport = K8s::Transport.new(
        "http://127.0.0.1:#{http_server.port}",
        socks5_proxy: "127.0.0.1:#{socks_proxy.port}"
      )

      transport.get('/api/v1')
      transport.get('/version')

      expect(http_server.requests).to include('/api/v1', '/version')
      expect(socks_proxy.connections.size).to be >= 2
    end
  end

  describe 'HTTPS request through SOCKS5 proxy' do
    let(:https_server) { nil } # Would need SSL setup

    it 'connects to HTTPS endpoints through proxy', skip: 'Requires SSL server setup' do
      # This test would verify HTTPS works through SOCKS5
    end
  end

  describe 'SOCKS5 proxy with authentication' do
    let(:auth_proxy) { TestSOCKS5Proxy.new(require_auth: true, username: 'testuser', password: 'testpass') }

    before do
      auth_proxy.start
    end

    after do
      auth_proxy.stop
    end

    it 'authenticates with username and password' do
      transport = K8s::Transport.new(
        "http://127.0.0.1:#{http_server.port}",
        socks5_proxy: "testuser:testpass@127.0.0.1:#{auth_proxy.port}"
      )

      result = transport.get('/api/v1')

      expect(result).to be_a(Hash)
      expect(result['kind']).to eq('APIResourceList')
    end

    it 'fails with wrong credentials' do
      transport = K8s::Transport.new(
        "http://127.0.0.1:#{http_server.port}",
        socks5_proxy: "wronguser:wrongpass@127.0.0.1:#{auth_proxy.port}"
      )

      expect { transport.get('/api/v1') }.to raise_error(Excon::Error::Socket)
    end

    it 'fails without credentials when auth required' do
      transport = K8s::Transport.new(
        "http://127.0.0.1:#{http_server.port}",
        socks5_proxy: "127.0.0.1:#{auth_proxy.port}"
      )

      expect { transport.get('/api/v1') }.to raise_error(Excon::Error::Socket)
    end
  end

  describe 'error handling' do
    it 'raises error when proxy is unreachable' do
      transport = K8s::Transport.new(
        "http://127.0.0.1:#{http_server.port}",
        socks5_proxy: "127.0.0.1:59999" # Non-existent proxy
      )

      expect { transport.get('/api/v1') }.to raise_error(Excon::Error::Socket)
    end

    it 'raises error when target is unreachable through proxy' do
      transport = K8s::Transport.new(
        "http://127.0.0.1:59998", # Non-existent target
        socks5_proxy: "127.0.0.1:#{socks_proxy.port}"
      )

      expect { transport.get('/api/v1') }.to raise_error(Excon::Error)
    end
  end
end
