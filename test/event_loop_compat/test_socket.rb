#
# Tests for the Socket / TCPSocket / TCPServer / UNIXServer layer of the
# EventLoopCompat PoC (equivalent to Coolio::Socket / TCPSocket /
# TCPServer / UNIXServer behavior).
#
# Run: bundle exec ruby -Ilib -Itest test/event_loop_compat/test_socket.rb
#

require 'test/unit'
require 'socket'
require 'tmpdir'

require 'event_loop_compat'

class EventLoopCompatSocketTest < Test::Unit::TestCase
  class EchoHandler < EventLoopCompat::TCPSocket
    def on_read(data)
      write(data)
    end
  end

  class RecordingHandler < EventLoopCompat::TCPSocket
    attr_reader :events

    def initialize(socket, events)
      @events = events
      @events << :init
      super(socket)
    end

    def on_connect
      @events << :on_connect
    end

    def on_read(data)
      @events << [:read, data]
    end

    def on_close
      @events << :on_close
    end
  end

  class UnixEchoHandler < EventLoopCompat::UNIXSocket
    def on_read(data)
      write(data)
    end
  end

  def setup
    @errors = []
    @loop = EventLoopCompat::Loop.new(error_handler: ->(watcher, error) {
      @errors << error
    })
  end

  def run_with_watchdog(loop, seconds = 2.0)
    wd = EventLoopCompat::TimerWatcher.new(seconds) { loop.stop }
    wd.attach(loop)
    loop.run
  end

  def free_tcp_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  def test_tcp_server_echo_with_async_client
    server = EventLoopCompat::TCPServer.new("127.0.0.1", 0, EchoHandler)
    port = server.io.addr[1]
    server.attach(@loop)

    result = nil
    t = EventLoopCompat::TimerWatcher.new(0.05) do
      client = EventLoopCompat::TCPSocket.connect("127.0.0.1", port)
      client.write("hello")
      client.on_read { |data| result = data; @loop.stop }
      client.attach(@loop)
    end
    t.attach(@loop)
    run_with_watchdog(@loop)

    assert_equal("hello", result)
    assert_equal([], @errors.map { |e| e.class.name })
  ensure
    server.close rescue nil
  end

  def test_tcp_server_connection_callback_order
    events = []
    server = EventLoopCompat::TCPServer.new("127.0.0.1", 0, RecordingHandler, events) do |conn|
      events << :block
    end
    port = server.io.addr[1]
    server.attach(@loop)

    t = EventLoopCompat::TimerWatcher.new(0.05) do
      client = TCPSocket.new("127.0.0.1", port)
      client.write("ping")
    end
    t.attach(@loop)
    t2 = EventLoopCompat::TimerWatcher.new(0.5) { @loop.stop }
    t2.attach(@loop)
    run_with_watchdog(@loop, 1.0)

    assert_equal([:init, :on_connect, :block], events.take(3))
    assert_equal([:read, "ping"], events[3])
    assert_equal([], @errors.map { |e| e.class.name })
  ensure
    server.close rescue nil
  end

  def test_client_on_connect_event_callback_fires
    server = EventLoopCompat::TCPServer.new("127.0.0.1", 0, EchoHandler)
    port = server.io.addr[1]
    server.attach(@loop)

    connected = false
    t = EventLoopCompat::TimerWatcher.new(0.05) do
      client = EventLoopCompat::TCPSocket.connect("127.0.0.1", port)
      client.on_connect { connected = true; @loop.stop }
      client.attach(@loop)
    end
    t.attach(@loop)
    run_with_watchdog(@loop)

    assert_true(connected, "on_connect must fire after the connect completes")
    assert_equal([], @errors.map { |e| e.class.name })
  ensure
    server.close rescue nil
  end

  def test_client_connect_failure_fires_on_connect_failed
    port = free_tcp_port
    begin
      client = EventLoopCompat::TCPSocket.connect("127.0.0.1", port)
    rescue Errno::ECONNREFUSED
      # Some platforms report the refusal synchronously from
      # connect_nonblock; cool.io propagates the same exception there.
      return
    end
    failed = false
    connected = false
    client.on_connect { connected = true; @loop.stop }
    client.on_connect_failed { failed = true; @loop.stop }
    client.attach(@loop)
    run_with_watchdog(@loop)

    unless failed
      so_error = begin
        client.to_io.getsockopt(::Socket::SOL_SOCKET, ::Socket::SO_ERROR).int
      rescue => e
        "#{e.class}: #{e.message}"
      end
      flunk("on_connect_failed must fire for a refused connection; " \
            "connected=#{connected}, attached=#{client.attached?}, " \
            "so_error=#{so_error}, errors=#{@errors.map { |e| [e.class.name, e.message] }.inspect}")
    end
    assert_raise(RuntimeError) { client.attach(@loop) }
    assert_equal([], @errors.map { |e| e.class.name })
  end

  def test_connector_watches_for_winsock_connect_failures
    server = TCPServer.new("127.0.0.1", 0)
    client = EventLoopCompat::TCPSocket.connect("127.0.0.1", server.addr[1])
    connector = client.instance_variable_get(:@connector)
    expected = IO::WRITABLE
    expected |= IO::PRIORITY if EventLoopCompat::WINDOWS
    assert_equal(expected, connector.instance_variable_get(:@events_mask))
  ensure
    client.to_io.close if client && !client.to_io.closed?
    server.close if server && !server.closed?
  end

  def test_connector_reports_failed_connect_on_priority_event
    failed = false
    owner = Object.new
    owner.define_singleton_method(:on_connect_failed) { failed = true }
    ruby_socket = Object.new
    ruby_socket.define_singleton_method(:getsockopt) { |*_args| [Errno::ECONNREFUSED::Errno].pack('i') }
    connector = EventLoopCompat::Socket::Connector.new(owner, ruby_socket)
    connector.attach(@loop)

    loop_fiber = Fiber.current
    waiting = nil
    selector = Object.new
    selector.define_singleton_method(:io_wait) do |fiber, _io, _events|
      waiting = fiber
      loop_fiber.transfer
    end
    @loop.instance_variable_set(:@selector, selector)
    connector.__start_runtime__(@loop)
    waiting.transfer(IO::PRIORITY)

    assert_true(failed)
    assert_false(connector.attached?)
  end

  def test_resolve_failure_fires_on_resolve_failed_on_attach
    client = EventLoopCompat::TCPSocket.connect("no-such-host.invalid", 1234)
    resolved = false
    client.on_resolve_failed { resolved = true }
    client.attach(@loop)
    assert_true(resolved, "on_resolve_failed must fire on attach for an unresolvable host")
    assert_raise(RuntimeError) { client.attach(@loop) }
  end

  def test_tcp_server_accepts_existing_listen_socket
    listen = TCPServer.new("127.0.0.1", 0)
    port = listen.addr[1]
    server = EventLoopCompat::TCPServer.new(listen, nil, EchoHandler)
    server.attach(@loop)

    result = nil
    t = EventLoopCompat::TimerWatcher.new(0.05) do
      client = EventLoopCompat::TCPSocket.connect("127.0.0.1", port)
      client.write("from-listen-socket")
      client.on_read { |data| result = data; @loop.stop }
      client.attach(@loop)
    end
    t.attach(@loop)
    run_with_watchdog(@loop)

    assert_equal("from-listen-socket", result)
  ensure
    server.close rescue nil
    listen.close rescue nil
  end

  def test_server_close_detaches_and_closes_listen_socket
    server = EventLoopCompat::TCPServer.new("127.0.0.1", 0, EchoHandler)
    server.attach(@loop)
    assert_true(server.attached?)

    t = EventLoopCompat::TimerWatcher.new(0.05) { server.close }
    t.attach(@loop)

    th = Thread.new { @loop.run }
    finished = !th.join(3).nil?
    assert_true(finished, "loop must exit after the only watcher closed")
    assert_false(server.attached?)
    assert_true(server.io.closed?)
  ensure
    server.close rescue nil
  end

  def test_server_rejects_wrong_handler_arity
    assert_raise(ArgumentError) do
      EventLoopCompat::TCPServer.new("127.0.0.1", 0, RecordingHandler)
    end
  end

  def test_unix_server_echo
    Dir.mktmpdir("event-loop-compat") do |dir|
      path = File.join(dir, "test.sock")
      server = EventLoopCompat::UNIXServer.new(path, UnixEchoHandler)
      server.attach(@loop)

      result = nil
      t = EventLoopCompat::TimerWatcher.new(0.05) do
        client = EventLoopCompat::UNIXSocket.connect(path)
        client.write("unix-hello")
        client.on_read { |data| result = data; @loop.stop }
        client.attach(@loop)
      end
      t.attach(@loop)
      run_with_watchdog(@loop)

      assert_equal("unix-hello", result)
      assert_equal([], @errors.map { |e| e.class.name })
      server.close rescue nil
    end
  end

  def test_client_close_calls_on_close
    server = EventLoopCompat::TCPServer.new("127.0.0.1", 0, EchoHandler)
    port = server.io.addr[1]
    server.attach(@loop)

    closed = false
    t = EventLoopCompat::TimerWatcher.new(0.05) do
      client = EventLoopCompat::TCPSocket.connect("127.0.0.1", port)
      client.on_close { closed = true; @loop.stop }
      client.attach(@loop)
      t2 = EventLoopCompat::TimerWatcher.new(0.1) { client.close }
      t2.attach(@loop)
    end
    t.attach(@loop)
    run_with_watchdog(@loop)

    assert_true(closed, "on_close must be called on local close")
    assert_equal([], @errors.map { |e| e.class.name })
  ensure
    server.close rescue nil
  end
end
