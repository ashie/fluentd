#
# External plugins attach Coolio watchers to the loop created by the
# event loop helper. That loop is an EventLoopCompat::Loop with the
# io_event_compat backend and a Coolio::Loop with the default backend;
# these tests run against both so the Coolio API keeps working the same
# way through the helper.
#

require_relative '../helper'
require 'fluent/plugin_helper/event_loop'
require 'fluent/plugin/base'
require 'cool.io'
require 'tmpdir'

class EventLoopCoolioWatchersTest < Test::Unit::TestCase
  class Dummy < Fluent::Plugin::TestBase
    helpers :event_loop

    def configure(conf)
      super
      @_event_loop_run_timeout = 0.1
    end
  end

  # cool.io has no block form for StatWatcher: the callback is an
  # overridden on_change, which external plugins rely on.
  class StatProbe < Coolio::StatWatcher
    attr_reader :changes

    def initialize(path)
      @changes = Queue.new
      super(path, 0.05)
    end

    def on_change(prev, cur)
      @changes << [prev.size, cur.size]
    end
  end

  def setup
    Fluent::Test.setup
    @d = Dummy.new
    @d.configure(config_element())
    @d.start
    @d.event_loop_wait_until_start
    assert @d.event_loop_running?
  end

  def teardown
    @d.shutdown
    @d.close
    @d.terminate
  end

  def test_timer_watcher_attached_to_the_loop_of_the_helper_fires
    timer = Coolio::TimerWatcher.new(0.1, true)
    ticks = Queue.new
    timer.on_timer { ticks << :tick }
    timer.attach(@d._event_loop)

    assert_equal :tick, wait_for(ticks)

    timer.detach
  end

  def test_io_watcher_attached_to_the_loop_of_the_helper_reads_data
    rd, wr = IO.pipe
    watcher = Coolio::IOWatcher.new(rd, 'r')
    readable = Queue.new
    watcher.on_readable { readable << rd.read_nonblock(100) }
    watcher.attach(@d._event_loop)

    wr.write "hello"
    assert_equal "hello", wait_for(readable)

    watcher.detach
    rd.close
    wr.close
  end

  def test_stat_watcher_attached_to_the_loop_of_the_helper_reports_changes
    Dir.mktmpdir("coolio-stat") do |dir|
      path = File.join(dir, "f")
      File.write(path, "a")

      stat = StatProbe.new(path)
      stat.attach(@d._event_loop)
      sleep 0.2

      # Renaming instead of rewriting avoids the window where the file
      # is truncated but not written yet: both backends can observe that
      # intermediate state and report it as a change.
      File.write("#{path}.new", "hello")
      File.rename("#{path}.new", path)
      change = wait_for(stat.changes)
      assert_not_nil(change, "no on_change callback for #{path}")
      assert_equal [1, 5], change

      stat.detach
    end
  end

  private

  def wait_for(queue, timeout = 5)
    deadline = Time.now + timeout
    while queue.empty? && Time.now < deadline
      sleep 0.05
    end
    queue.empty? ? nil : queue.pop
  end
end
