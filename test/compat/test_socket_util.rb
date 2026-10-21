#
# Tests for the legacy compat socket API (Fluent::Compat::SocketUtil)
# on the selected event loop backend.
#
# Run: bundle exec ruby -Ilib -Itest test/compat/test_socket_util.rb
#

require_relative '../helper'
require 'fluent/compat/socket_util'

class CompatSocketUtilTest < ::Test::Unit::TestCase
  SocketUtil = Fluent::Compat::SocketUtil

  def setup
    Fluent::Test.setup
  end

  def test_base_classes_match_the_selected_backend
    if Fluent::PluginHelper::EventLoop::EVENT_LOOP_BACKEND == :io_event_compat
      assert_equal EventLoopCompat::Loop, SocketUtil::LOOP_BASE
      assert_equal EventLoopCompat::Socket, SocketUtil::SOCKET_BASE
      assert_equal EventLoopCompat::BufferedIO, SocketUtil::IO_BASE
    else
      assert_equal Coolio::Loop, SocketUtil::LOOP_BASE
      assert_equal Coolio::Socket, SocketUtil::SOCKET_BASE
      assert_equal Coolio::IO, SocketUtil::IO_BASE
    end
  end

  # The legacy input API must keep working on the selected backend:
  # a TcpHandler attached to a loop must dispatch delimited messages
  # to the callback, as the old in_tcp / in_syslog inputs did.
  def test_tcp_handler_receives_delimited_messages
    server = TCPServer.new('127.0.0.1', 0)
    client = TCPSocket.new('127.0.0.1', server.addr[1])
    io = server.accept

    messages = []
    handler = SocketUtil::TcpHandler.new(io, $log, "\n", ->(msg, _addr) { messages << msg })
    evloop = SocketUtil::LOOP_BASE.new
    handler.attach(evloop)

    runner = Thread.new { evloop.run(0.1) }
    begin
      client.write("one\ntwo\n")
      timeout = Time.now + 5
      while messages.size < 2 && Time.now < timeout
        sleep 0.05
      end
    ensure
      # Same shutdown sequence as SocketUtil::BaseInput#shutdown.
      evloop.watchers.each { |w| w.detach }
      evloop.stop if evloop.instance_variable_get(:@running)
      runner.join
    end

    assert_equal ["one", "two"], messages
  ensure
    client.close if client
    io.close if io
    server.close if server
  end
end
