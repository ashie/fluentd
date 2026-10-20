#
# Tests for the EventLoopCompat PoC layer (io-event based).
#
# Run: bundle exec ruby -Ilib -Itest test/event_loop_compat/test_loop.rb
#
# These tests are intentionally standalone: they do not use Fluentd's
# test helpers because the PoC is independent from Fluentd itself.
#

require 'test/unit'
require 'socket'

require 'event_loop_compat'

class EventLoopCompatTest < Test::Unit::TestCase
  WATCHDOG_SECONDS = 1.5

  def setup
    @errors = []
    @loop = EventLoopCompat::Loop.new(error_handler: ->(watcher, error) {
      @errors << error
    })
  end

  # Run the loop until the watchdog timer stops it.
  def run_with_watchdog(loop, seconds = 0.5)
    wd = EventLoopCompat::TimerWatcher.new(seconds) { loop.stop }
    wd.attach(loop)
    loop.run
  end

  # Run the loop in a thread and report whether it finished by itself.
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

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  #
  # timers
  #

  def test_repeat_timer_fires_multiple_times
    fired = 0
    tw = EventLoopCompat::TimerWatcher.new(0.05, true) { fired += 1 }
    tw.attach(@loop)
    run_with_watchdog(@loop)
    assert_operator(fired, :>=, 4, "repeat timer should fire repeatedly")
    assert_equal([], @errors.map { |e| e.class.name })
  end

  def test_oneshot_timer_fires_only_once
    fired = 0
    tw = EventLoopCompat::TimerWatcher.new(0.05) { fired += 1 }
    tw.attach(@loop)
    # No watchdog: the loop must exit by itself when the one-shot timer
    # is not re-armed and no other watcher is active.
    finished, err = run_in_thread(@loop)
    assert_true(finished, "loop did not exit after one-shot timer: #{err.inspect}")
    assert_equal(1, fired)
    assert_false(tw.enabled?, "one-shot timer should not stay enabled")
    assert_true(tw.attached?, "one-shot timer should stay attached")
  end

  def test_repeat_timer_interval_is_monotonic
    times = []
    tw = EventLoopCompat::TimerWatcher.new(0.05, true) { times << monotonic }
    tw.attach(@loop)
    run_with_watchdog(@loop, 0.4)
    assert_operator(times.size, :>=, 4)
    diffs = times.each_cons(2).map { |a, b| b - a }
    # libev-like fixed schedule: intervals around 0.05, never much less.
    assert_operator(diffs.min, :>=, 0.03, "timer intervals must not be too short")
    assert_operator(diffs.max, :<, 0.3, "timer intervals must not drift too much")
  end

  def test_detach_stops_timer_callback
    fired = 0
    tw = nil
    tw = EventLoopCompat::TimerWatcher.new(0.05, true) do
      fired += 1
      tw.detach if fired == 1
    end
    tw.attach(@loop)
    run_with_watchdog(@loop)
    assert_equal(1, fired, "detached watcher must not fire again")
    assert_false(tw.attached?)
  end

  def test_detach_from_another_thread
    fired = 0
    detached = false
    tw = EventLoopCompat::TimerWatcher.new(0.05, true) do
      fired += 1
    end
    tw.attach(@loop)
    detacher = Thread.new do
      sleep 0.15
      tw.detach
      detached = true
    end
    # keeper keeps the loop alive after the detach
    keeper = EventLoopCompat::TimerWatcher.new(0.05, true) { }
    keeper.attach(@loop)
    run_with_watchdog(@loop)
    detacher.join
    assert_true(detached)
    # With 0.05s interval and a 0.5s run, more than ~6 firings would
    # mean the timer kept running after detach.
    assert_operator(fired, :<=, 6, "timer kept firing after detach: #{fired}")
  end

  def test_double_detach_is_safe
    tw = EventLoopCompat::TimerWatcher.new(0.05, true) { }
    tw.attach(@loop)
    tw.detach
    tw.detach
    assert_false(tw.attached?)
  end

  def test_disable_and_enable_timer
    times = []
    tw = EventLoopCompat::TimerWatcher.new(0.05, true) { times << monotonic }
    tw.attach(@loop)

    start = nil
    disabler = Thread.new do
      sleep 0.15
      @loop.disable(tw)
    end
    enabler = Thread.new do
      sleep 0.35
      @loop.enable(tw)
    end
    start = monotonic
    run_with_watchdog(@loop, 0.6)
    disabler.join
    enabler.join

    rel = times.map { |t| t - start }
    assert_true(rel.any? { |t| t < 0.15 }, "expected firings before disable")
    assert_true(rel.none? { |t| t > 0.22 && t < 0.35 }, "no firings while disabled: #{rel.inspect}")
    assert_true(rel.any? { |t| t > 0.40 }, "expected firings after re-enable")
  end

  #
  # IO watchers
  #

  def test_readable_event_on_socketpair
    sock1, sock2 = UNIXSocket.pair
    received = nil
    w = EventLoopCompat::IOWatcher.new(sock1) do |watcher|
      received = watcher.io.read_nonblock(100)
      @loop.stop
    end
    w.attach(@loop)
    sender = EventLoopCompat::TimerWatcher.new(0.05) { sock2.write("hello") }
    sender.attach(@loop)
    run_with_watchdog(@loop)
    assert_equal("hello", received)
  ensure
    sock1.close rescue nil
    sock2.close rescue nil
  end

  def test_readable_event_on_udp
    udp = UDPSocket.new
    udp.bind("127.0.0.1", 0)
    port = udp.addr[1]
    received = nil
    w = EventLoopCompat::IOWatcher.new(udp) do |watcher|
      data, _ = watcher.io.recvfrom(100)
      received = data
      @loop.stop
    end
    w.attach(@loop)
    sender = EventLoopCompat::TimerWatcher.new(0.05) { udp.send("ping", 0, "127.0.0.1", port) }
    sender.attach(@loop)
    run_with_watchdog(@loop)
    assert_equal("ping", received)
  ensure
    udp.close rescue nil
  end

  def test_detach_io_watcher_stops_callback
    sock1, sock2 = UNIXSocket.pair
    called = 0
    w = EventLoopCompat::IOWatcher.new(sock1) { called += 1 }
    w.attach(@loop)
    first = EventLoopCompat::TimerWatcher.new(0.05) { w.detach }
    first.attach(@loop)
    # data arrives only after the watcher has been detached
    sender = EventLoopCompat::TimerWatcher.new(0.2, true) { sock2.write("x") }
    sender.attach(@loop)
    run_with_watchdog(@loop)
    assert_equal(0, called, "detached IO watcher must not fire")
  ensure
    sock1.close rescue nil
    sock2.close rescue nil
  end

  def test_disable_and_enable_io_watcher
    sock1, sock2 = UNIXSocket.pair
    called = 0
    w = EventLoopCompat::IOWatcher.new(sock1) { called += 1 }
    w.attach(@loop)
    sender = EventLoopCompat::TimerWatcher.new(0.05, true) { sock2.write("x") rescue nil }
    sender.attach(@loop)

    disabler = Thread.new { sleep 0.1; @loop.disable(w) }
    enabler = Thread.new { sleep 0.3; @loop.enable(w) }
    run_with_watchdog(@loop, 0.5)
    disabler.join
    enabler.join

    assert_operator(called, :>=, 1, "IO watcher should fire before disable")
    assert_equal([], @errors.map { |e| e.class.name })
  ensure
    sock1.close rescue nil
    sock2.close rescue nil
  end

  def test_closed_io_does_not_break_loop
    r, w = IO.pipe
    r.close
    called = 0
    iw = EventLoopCompat::IOWatcher.new(r) { called += 1 }
    iw.attach(@loop)
    sender = EventLoopCompat::TimerWatcher.new(0.05, true) { w.write("x") rescue nil }
    sender.attach(@loop)
    run_with_watchdog(@loop, 0.3)
    assert_equal(0, called, "callback must not run for a closed IO")
  ensure
    w.close rescue nil
  end

  def test_close_io_while_waiting
    r, w = IO.pipe
    iw = EventLoopCompat::IOWatcher.new(r) { }
    iw.attach(@loop)
    closer = EventLoopCompat::TimerWatcher.new(0.1) { r.close }
    closer.attach(@loop)
    run_with_watchdog(@loop, 0.3)
    # The loop must finish normally regardless of the closed IO.
    assert_equal([], @errors.reject { |e| e.is_a?(IO::WaitReadable) })
  ensure
    w.close rescue nil
  end

  #
  # loop control
  #

  def test_run_without_watchers_raises
    assert_raise(RuntimeError) { @loop.run }
  end

  def test_stop_from_another_thread
    tw = EventLoopCompat::TimerWatcher.new(0.05, true) { }
    tw.attach(@loop)
    stopper = Thread.new do
      sleep 0.2
      @loop.stop
    end
    start = monotonic
    @loop.run
    elapsed = monotonic - start
    stopper.join
    assert_operator(elapsed, :>=, 0.15, "loop must not spin without events")
    assert_operator(elapsed, :<, 2.0, "loop must stop when requested")
    assert_false(@loop.running?)
    assert_false(@loop.stop, "second stop must be safe and return false")
  end

  def test_run_returns_when_all_watchers_detached
    tw = nil
    tw = EventLoopCompat::TimerWatcher.new(0.05, true) do |watcher|
      watcher.detach
    end
    tw.attach(@loop)
    finished, err = run_in_thread(@loop)
    assert_true(finished, "loop must return when all watchers are detached: #{err.inspect}")
    assert_false(tw.attached?)
  end

  def test_attach_from_another_thread
    fired = 0
    keeper = EventLoopCompat::TimerWatcher.new(0.05, true) { }
    keeper.attach(@loop)
    attacher = Thread.new do
      sleep 0.15
      tw = EventLoopCompat::TimerWatcher.new(0.05, true) { fired += 1 }
      tw.attach(@loop)
    end
    run_with_watchdog(@loop, 0.5)
    attacher.join
    assert_operator(fired, :>=, 2, "watcher attached from another thread must run")
  end

  #
  # error handling
  #

  def test_timer_callback_exception_does_not_stop_loop
    fired = 0
    tw = EventLoopCompat::TimerWatcher.new(0.05, true) do
      fired += 1
      raise "boom"
    end
    tw.attach(@loop)
    run_with_watchdog(@loop)
    assert_operator(fired, :>=, 3, "loop must keep running after callback errors")
    assert_operator(@errors.size, :>=, 3)
    assert_kind_of(RuntimeError, @errors.first)
  end

  def test_io_callback_exception_does_not_stop_loop
    sock1, sock2 = UNIXSocket.pair
    called = 0
    w = EventLoopCompat::IOWatcher.new(sock1) do
      called += 1
      raise "io boom"
    end
    w.attach(@loop)
    sender = EventLoopCompat::TimerWatcher.new(0.05, true) { sock2.write("x") rescue nil }
    sender.attach(@loop)
    run_with_watchdog(@loop)
    assert_operator(called, :>=, 2, "IO watcher must keep working after callback errors")
    assert_operator(@errors.size, :>=, 2)
  ensure
    sock1.close rescue nil
    sock2.close rescue nil
  end
end
