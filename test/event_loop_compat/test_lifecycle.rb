#
# Tests for runtime resource cleanup of the EventLoopCompat PoC layer:
# fibers, park pipes and timer handles must be released deterministically
# when the loop stops, and watchers must be reusable across runs.
#
# Run: bundle exec ruby -Ilib -Itest test/event_loop_compat/test_lifecycle.rb
#

require 'test/unit'
require 'socket'

require 'event_loop_compat'

class EventLoopCompatLifecycleTest < Test::Unit::TestCase
  def setup
    @errors = []
    @loop = EventLoopCompat::Loop.new(error_handler: ->(watcher, error) {
      @errors << error
    })
  end

  def stop_after(seconds)
    th = Thread.new do
      sleep seconds
      @loop.stop
    end
    th
  end

  def test_runtime_resources_released_when_loop_stops
    sock1, sock2 = UNIXSocket.pair
    iow = EventLoopCompat::IOWatcher.new(sock1) { }
    iow.attach(@loop)
    # park the fiber (creates the park pipe) before stopping the loop
    disabler = EventLoopCompat::TimerWatcher.new(0.05) { iow.disable }
    disabler.attach(@loop)

    stopper = stop_after(0.2)
    @loop.run
    stopper.join

    assert_false(@loop.running?)
    assert_nil(iow.instance_variable_get(:@fiber), "fiber reference must be cleared")
    assert_nil(iow.instance_variable_get(:@park_reader), "park pipe must be closed")
    assert_nil(iow.instance_variable_get(:@park_writer), "park pipe must be closed")
    assert_nil(disabler.instance_variable_get(:@handle), "timer handle must be cancelled")
    # watchers stay attached, like Coolio
    assert_true(iow.attached?)
    assert_equal([], @errors.map { |e| e.class.name })
  ensure
    sock1.close rescue nil
    sock2.close rescue nil
  end

  def test_detach_while_parked_finishes_fiber
    sock1, sock2 = UNIXSocket.pair
    iow = EventLoopCompat::IOWatcher.new(sock1) { }
    iow.attach(@loop)
    disabler = EventLoopCompat::TimerWatcher.new(0.05) { iow.disable }
    disabler.attach(@loop)
    detacher = EventLoopCompat::TimerWatcher.new(0.1) { iow.detach }
    detacher.attach(@loop)

    stopper = stop_after(0.2)
    @loop.run
    stopper.join

    assert_false(iow.attached?)
    assert_nil(iow.instance_variable_get(:@fiber))
    assert_nil(iow.instance_variable_get(:@park_reader))
    assert_equal([], @errors.map { |e| e.class.name })
  ensure
    sock1.close rescue nil
    sock2.close rescue nil
  end

  def test_watchers_are_reusable_across_runs
    fired = 0
    read = 0
    sock1, sock2 = UNIXSocket.pair
    iow = EventLoopCompat::IOWatcher.new(sock1) { read += 1 }
    iow.attach(@loop)
    tw = EventLoopCompat::TimerWatcher.new(0.05, true) { fired += 1 }
    tw.attach(@loop)

    stopper = stop_after(0.2)
    @loop.run
    stopper.join
    first_fired = fired
    assert_operator(first_fired, :>=, 1, "timer must fire in the first run")

    # second run with the same attached watchers
    sock2.write("x")
    stopper = stop_after(0.2)
    @loop.run
    stopper.join

    assert_operator(fired, :>=, first_fired + 1, "timer must fire again in the second run")
    assert_operator(read, :>=, 1, "IO watcher must work in the second run")
    assert_equal([], @errors.map { |e| e.class.name })
  ensure
    sock1.close rescue nil
    sock2.close rescue nil
  end

  def test_no_fd_leak_after_runs
    omit "requires /proc/self/fd" unless File.directory?("/proc/self/fd")

    baseline = Dir.glob("/proc/self/fd/*").size
    5.times do
      sock1, sock2 = UNIXSocket.pair
      iow = EventLoopCompat::IOWatcher.new(sock1) { }
      iow.attach(@loop)
      disabler = EventLoopCompat::TimerWatcher.new(0.05) { iow.disable }
      disabler.attach(@loop)
      stopper = stop_after(0.1)
      @loop.run
      stopper.join
      iow.detach
      disabler.detach
      sock1.close
      sock2.close
    end
    GC.start

    # the glob itself holds one fd while counting, allow a small margin
    assert_operator(Dir.glob("/proc/self/fd/*").size, :<=, baseline + 2)
  end
end
