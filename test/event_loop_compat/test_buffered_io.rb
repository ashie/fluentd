#
# Tests for the writable / buffered-write / close semantics of the
# EventLoopCompat PoC layer (equivalent to Coolio::IO behavior).
#
# Run: bundle exec ruby -Ilib -Itest test/event_loop_compat/test_buffered_io.rb
#

require 'test/unit'
require 'socket'

require 'event_loop_compat'

class EventLoopCompatBufferedIOTest < Test::Unit::TestCase
  class WriteCounter < EventLoopCompat::IOWatcher
    attr_reader :called

    def initialize(io)
      super(io, :w)
      @called = 0
    end

    def on_writable
      @called += 1
      disable
    end
  end

  class RecordingIO < EventLoopCompat::BufferedIO
    attr_reader :received, :write_completed, :closed_called

    def initialize(io, echo: false)
      super(io)
      @echo = echo
      @received = +""
      @write_completed = false
      @closed_called = false
    end

    def on_read(data)
      @received << data
      write(data) if @echo
    end

    def on_write_complete
      @write_completed = true
    end

    def on_close
      @closed_called = true
    end
  end

  def setup
    @errors = []
    @loop = EventLoopCompat::Loop.new(error_handler: ->(watcher, error) {
      @errors << error
    })
  end

  def run_with_watchdog(loop, seconds = 0.5)
    wd = EventLoopCompat::TimerWatcher.new(seconds) { loop.stop }
    wd.attach(loop)
    loop.run
  end

  def run_in_thread(loop, timeout = 3)
    th = Thread.new do
      begin
        loop.run
      rescue => e
        e
      end
    end
    finished = !th.join(timeout).nil?
    [finished, finished ? th.value : nil]
  end

  def test_writable_event_fires_until_disabled
    r, w = IO.pipe
    wc = WriteCounter.new(w)
    wc.attach(@loop)
    run_with_watchdog(@loop, 0.3)
    assert_equal(1, wc.called, "write interest must fire once then stay disabled")
    assert_equal([], @errors.map { |e| e.class.name })
  ensure
    r.close rescue nil
    w.close rescue nil
  end

  def test_invalid_flags_are_rejected
    r, w = IO.pipe
    assert_raise(ArgumentError) { EventLoopCompat::IOWatcher.new(w, :bogus) }
    assert_raise(ArgumentError) { EventLoopCompat::IOWatcher.new(w, :rw) { } }
  ensure
    r.close rescue nil
    w.close rescue nil
  end

  def test_buffered_io_echo_and_eof_triggers_on_close
    sock1, sock2 = UNIXSocket.pair
    echo = RecordingIO.new(sock1, echo: true)
    echo.attach(@loop)

    received = nil
    t1 = EventLoopCompat::TimerWatcher.new(0.05) { sock2.write("hello") }
    t1.attach(@loop)
    t2 = EventLoopCompat::TimerWatcher.new(0.2) do
      begin
        received = sock2.read_nonblock(100)
      rescue IO::WaitReadable
      end
    end
    t2.attach(@loop)
    # closing the peer must surface as EOF and close the BufferedIO
    t3 = EventLoopCompat::TimerWatcher.new(0.3) { sock2.close }
    t3.attach(@loop)

    run_with_watchdog(@loop, 0.6)

    assert_equal("hello", received)
    assert_equal("hello", echo.received)
    assert_true(echo.write_completed, "on_write_complete must be called when buffer drains")
    assert_true(echo.closed_called, "on_close must be called on EOF")
    assert_true(sock1.closed?)
    assert_equal([], @errors.map { |e| e.class.name })
  ensure
    sock1.close rescue nil
    sock2.close rescue nil
  end

  def test_buffered_io_write_before_attach_is_flushed
    sock1, sock2 = UNIXSocket.pair
    bio = RecordingIO.new(sock1)
    bio.write("early-data")
    bio.attach(@loop)

    received = nil
    t = EventLoopCompat::TimerWatcher.new(0.2) do
      begin
        received = sock2.read_nonblock(100)
      rescue IO::WaitReadable
      end
    end
    t.attach(@loop)
    run_with_watchdog(@loop, 0.4)

    assert_equal("early-data", received)
  ensure
    sock1.close rescue nil
    sock2.close rescue nil
  end

  def test_local_close_calls_on_close_and_detaches
    sock1, _sock2 = UNIXSocket.pair
    bio = RecordingIO.new(sock1)
    bio.attach(@loop)
    t = EventLoopCompat::TimerWatcher.new(0.05) { bio.close }
    t.attach(@loop)

    # after close all watchers are detached, so the loop must exit by itself
    finished, err = run_in_thread(@loop)
    assert_true(finished, "loop must exit after the only watcher closed: #{err.inspect}")
    assert_true(bio.closed_called)
    assert_true(sock1.closed?)
    assert_false(bio.attached?)
  ensure
    sock1.close rescue nil
  end

  def test_close_after_write_waits_for_both_watchers_to_exit
    sock1, sock2 = UNIXSocket.pair
    bio = Class.new(RecordingIO) do
      def on_write_complete
        super
        close
      end
    end.new(sock1)
    closed_while_fibers_alive = nil
    sock1.define_singleton_method(:close) do
      closed_while_fibers_alive = [bio.instance_variable_get(:@read_watcher).fiber_alive?,
                                  bio.instance_variable_get(:@write_watcher).fiber_alive?]
      super()
    end

    bio.attach(@loop)
    bio.write("done")
    run_with_watchdog(@loop)

    assert_equal([false, false], closed_while_fibers_alive)
    assert_equal(0, bio.instance_variable_get(:@write_buffer_size))
    assert_true(bio.write_completed)
    assert_equal("done", sock2.read_nonblock(4))
    assert_true(sock1.closed?)
    assert_equal([], @errors.map { |e| e.class.name })
  ensure
    sock1.close rescue nil
    sock2.close rescue nil
  end

  def test_large_write_is_flushed_in_chunks
    payload = "x" * (256 * 1024)
    sock1, sock2 = UNIXSocket.pair
    bio = RecordingIO.new(sock1)
    bio.attach(@loop)

    got = +""
    done = false
    t1 = EventLoopCompat::TimerWatcher.new(0.05) { bio.write(payload) }
    t1.attach(@loop)
    reader = EventLoopCompat::TimerWatcher.new(0.05, true) do
      begin
        while true
          got << sock2.read_nonblock(16 * 1024)
        end
      rescue IO::WaitReadable
      end
      if got.bytesize >= payload.bytesize
        done = true
        @loop.stop
      end
    end
    reader.attach(@loop)
    run_with_watchdog(@loop, 3.0)

    assert_true(done, "did not receive all data: #{got.bytesize}/#{payload.bytesize}")
    assert_equal(payload.bytesize, got.bytesize)
    assert_equal(payload, got)
    assert_true(bio.write_completed, "on_write_complete must fire after full flush")
    assert_equal([], @errors.map { |e| e.class.name })
  ensure
    sock1.close rescue nil
    sock2.close rescue nil
  end

  def test_small_writes_are_sent_together
    writes = []
    io = Object.new
    io.define_singleton_method(:closed?) { false }
    io.define_singleton_method(:write_nonblock) do |data|
      writes << data
      data.bytesize
    end
    bio = RecordingIO.new(io)
    header = "Content-Length: 2\r\n\r\n".freeze
    body = "\xFF\xFE".b

    bio.write(header)
    bio.write(body)
    bio.send(:flush_write_buffer)

    assert_equal([header.b + body], writes)
    assert_equal(0, bio.instance_variable_get(:@write_buffer_size))
  end

  def test_coalesced_writes_preserve_remaining_data_when_write_would_block
    writes = []
    io = Object.new
    io.define_singleton_method(:closed?) { false }
    io.define_singleton_method(:write_nonblock) do |data|
      writes << data
      case writes.size
      when 1 then 3
      when 2 then raise IO::EAGAINWaitWritable
      else data.bytesize
      end
    end
    bio = RecordingIO.new(io)
    bio.write("header")
    bio.write("body")

    assert_raise(IO::EAGAINWaitWritable) { bio.send(:flush_write_buffer) }
    assert_equal(7, bio.instance_variable_get(:@write_buffer_size))
    bio.send(:flush_write_buffer)

    assert_equal(["headerbody", "derbody", "derbody"], writes)
    assert_equal(0, bio.instance_variable_get(:@write_buffer_size))
    assert_empty(bio.instance_variable_get(:@write_buffer))
  end
end
