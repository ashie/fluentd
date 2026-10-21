#
# Tests for the polling-based StatWatcher of the EventLoopCompat PoC
# layer (Coolio::StatWatcher / libev ev_stat replacement).
#
# Run: bundle exec ruby -Ilib -Itest test/event_loop_compat/test_stat_watcher.rb
#

require 'test/unit'
require 'tmpdir'
require 'fileutils'

require 'event_loop_compat'

class EventLoopCompatStatWatcherTest < Test::Unit::TestCase
  INTERVAL = 0.05

  def setup
    @errors = []
    @loop = EventLoopCompat::Loop.new(error_handler: ->(watcher, error) {
      @errors << error
    })
    @dir = Dir.mktmpdir("event-loop-compat-stat")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def path
    File.join(@dir, "watched.txt")
  end

  def write_file(text)
    File.open(path, "w") { |f| f.write(text) }
  end

  def test_change_is_detected
    write_file("one")
    changes = []
    sw = EventLoopCompat::StatWatcher.new(path, INTERVAL) { |prev, cur| changes << [prev, cur] }
    sw.attach(@loop)
    writer = EventLoopCompat::TimerWatcher.new(0.2, true) do
      write_file("two-and-longer")
    end
    writer.attach(@loop)
    wd = EventLoopCompat::TimerWatcher.new(0.8) { @loop.stop }
    wd.attach(@loop)
    @loop.run

    # no startup firing (cool.io / libev only seeds the baseline),
    # the first event is the rewrite change
    assert_true(changes.size >= 1, "expected at least the rewrite change, got #{changes.size}")
    first_prev, first_cur = changes.first
    assert_not_equal(0, first_prev.mode, "no startup firing expected")
    assert_equal(3, first_prev.size)
    assert_equal("two-and-longer".bytesize, first_cur.size)
    assert_equal([], @errors.map { |e| e.class.name })
  end

  def test_appearance_and_removal_are_detected
    changes = []
    sw = EventLoopCompat::StatWatcher.new(path, INTERVAL) { |prev, cur| changes << [prev, cur] }
    sw.attach(@loop)
    creator = EventLoopCompat::TimerWatcher.new(0.15) { write_file("x") }
    creator.attach(@loop)
    remover = EventLoopCompat::TimerWatcher.new(0.35) { File.delete(path) }
    remover.attach(@loop)
    wd = EventLoopCompat::TimerWatcher.new(0.6) { @loop.stop }
    wd.attach(@loop)
    @loop.run

    appear = changes.find { |(prev, cur)| prev.mode.zero? && !cur.mode.zero? }
    assert_not_nil(appear, "appearance must fire with a zeroed prev")
    removal = changes.find { |(_prev, cur)| cur.mode.zero? }
    assert_not_nil(removal, "file removal must be detected")
    assert_equal([], @errors.map { |e| e.class.name })
  end

  def test_no_change_means_no_callback
    write_file("stable")
    changes = 0
    sw = EventLoopCompat::StatWatcher.new(path, INTERVAL) { |_prev, _cur| changes += 1 }
    sw.attach(@loop)
    wd = EventLoopCompat::TimerWatcher.new(0.3) { @loop.stop }
    wd.attach(@loop)
    @loop.run

    # no startup firing and no change: no callback at all
    assert_equal(0, changes)
    assert_equal([], @errors.map { |e| e.class.name })
  end

  def test_default_interval_is_accepted
    sw = EventLoopCompat::StatWatcher.new(path)
    assert_equal(EventLoopCompat::StatWatcher::DEFAULT_INTERVAL, sw.interval)
    sw2 = EventLoopCompat::StatWatcher.new(path, 0)
    assert_equal(EventLoopCompat::StatWatcher::DEFAULT_INTERVAL, sw2.interval)
  end

  # Regression: the internal polling timer is owned by the watcher and
  # must not survive as a loop watcher across runs.
  def test_internal_timer_does_not_accumulate_across_runs
    write_file("one")
    sw = EventLoopCompat::StatWatcher.new(path, INTERVAL) { |_prev, _cur| }
    sw.attach(@loop)
    3.times do
      wd = EventLoopCompat::TimerWatcher.new(0.1) { @loop.stop }
      wd.attach(@loop)
      @loop.run
      wd.detach
      assert_equal(1, @loop.watchers.size, "loop watcher set must not grow across runs")
      assert_nil(sw.instance_variable_get(:@handle), "internal timer handle must be released")
    end
    assert_equal([], @errors.map { |e| e.class.name })
  end

  # The loop must exit when the only watcher is detached from another
  # thread: the detached watcher's internal timer must not keep it alive.
  def test_detached_from_thread_exits_loop
    write_file("one")
    sw = EventLoopCompat::StatWatcher.new(path, INTERVAL) { |_prev, _cur| }
    sw.attach(@loop)
    detacher = Thread.new do
      sleep 0.15
      sw.detach
    end
    th = Thread.new { @loop.run }
    finished = !th.join(2).nil?
    detacher.join
    assert_true(finished, "loop must return when the only watcher is detached")
    assert_false(sw.attached?)
    assert_nil(sw.instance_variable_get(:@handle), "internal timer handle must be released")
  end

  # The inotify fast path (Linux) must detect changes immediately, far
  # before the polling interval would fire.
  def test_inotify_fast_path_detects_change_immediately
    skip "inotify fast path is not supported on this platform" unless EventLoopCompat::Inotify.supported?

    write_file("one")
    changes = []
    sw = EventLoopCompat::StatWatcher.new(path, 30.0) { |_prev, cur| changes << cur }
    sw.attach(@loop)
    writer = EventLoopCompat::TimerWatcher.new(0.2) { write_file("two") }
    writer.attach(@loop)
    wd = EventLoopCompat::TimerWatcher.new(1.0) { @loop.stop }
    wd.attach(@loop)
    @loop.run

    assert_true(changes.size >= 1, "inotify must detect the change long before the 30s interval")
    assert_equal("two".bytesize, changes.first.size)
    assert_equal([], @errors.map { |e| e.class.name })
  end

  # Replacement of the watched file by a rename (what in_tail rotation
  # looks like) must be detected through the parent directory watch.
  def test_inotify_fast_path_detects_rename_replacement
    skip "inotify fast path is not supported on this platform" unless EventLoopCompat::Inotify.supported?

    write_file("one")
    changes = []
    sw = EventLoopCompat::StatWatcher.new(path, 30.0) { |_prev, cur| changes << cur }
    sw.attach(@loop)
    rotator = EventLoopCompat::TimerWatcher.new(0.2) do
      File.rename(path, path + ".bak")
      write_file("fresh")
    end
    rotator.attach(@loop)
    wd = EventLoopCompat::TimerWatcher.new(1.0) { @loop.stop }
    wd.attach(@loop)
    @loop.run

    assert_true(changes.size >= 1, "inotify must detect the rename/replacement immediately")
    assert_true(changes.any? { |cur| cur.size == "fresh".bytesize },
                "expected a change to the replacement file, got #{changes.map(&:size)}")
    assert_equal([], @errors.map { |e| e.class.name })
  end

  # All stat watchers of one loop must share a single inotify instance
  # (like libev does). One instance per watcher would grow the fd count
  # with the number of watched files, and in_tail with many files would
  # hit the fd limit and silently fall back to slow polling.
  def test_inotify_instance_is_shared_across_watchers
    skip "inotify fast path is not supported on this platform" unless EventLoopCompat::Inotify.supported?
    skip "requires /proc/self/fd" unless File.directory?("/proc/self/fd")

    paths = 3.times.map { |i| File.join(@dir, "shared#{i}.txt") }
    paths.each { |p| File.write(p, "one") }
    baseline = inotify_fd_count
    changes = []
    watchers = paths.map do |p|
      EventLoopCompat::StatWatcher.new(p, 30.0) { |_prev, cur| changes << [p, cur.size] }
    end
    watchers.each { |w| w.attach(@loop) }

    counts = []
    checker = EventLoopCompat::TimerWatcher.new(0.3) { counts << inotify_fd_count }
    checker.attach(@loop)
    writer = EventLoopCompat::TimerWatcher.new(0.5) do
      paths.each { |p| File.write(p, "two-two") }
    end
    writer.attach(@loop)
    wd = EventLoopCompat::TimerWatcher.new(1.2) { @loop.stop }
    wd.attach(@loop)
    @loop.run

    assert_equal([baseline + 1], counts.uniq, "exactly one inotify fd must serve all watchers")
    assert_equal(3, changes.map(&:first).uniq.size, "every watched file must still be detected")
    watchers.each(&:detach)
    assert_equal(baseline, inotify_fd_count, "the shared inotify fd must be closed with the last watcher")
    assert_equal([], @errors.map { |e| e.class.name })
  end

  # The parent directory watch must detect the creation of a file that
  # did not exist when the watch started (regression: a wrong
  # IN_ONLYDIR value made inotify_add_watch fail with EINVAL, leaving
  # only the polling fallback).
  def test_inotify_fast_path_detects_appearance_of_missing_file
    skip "inotify fast path is not supported on this platform" unless EventLoopCompat::Inotify.supported?

    changes = []
    sw = EventLoopCompat::StatWatcher.new(path, 30.0) { |prev, cur| changes << [prev, cur] }
    sw.attach(@loop)
    creator = EventLoopCompat::TimerWatcher.new(0.2) { write_file("created") }
    creator.attach(@loop)
    wd = EventLoopCompat::TimerWatcher.new(1.0) { @loop.stop }
    wd.attach(@loop)
    @loop.run

    appear = changes.find { |(prev, cur)| prev.mode.zero? && !cur.mode.zero? }
    assert_not_nil(appear, "the directory watch must detect creation long before the 30s interval")
    assert_equal("created".bytesize, appear.last.size)
    assert_equal([], @errors.map { |e| e.class.name })
  end

  # When the kernel drops the last watch of the shared instance (the
  # watched file and its parent directory are removed), the instance
  # must close itself: no inotify fd and no loop watcher may be left
  # behind while the loop keeps running.
  def test_inotify_instance_is_closed_when_kernel_drops_last_watch
    skip "inotify fast path is not supported on this platform" unless EventLoopCompat::Inotify.supported?
    skip "requires /proc/self/fd" unless File.directory?("/proc/self/fd")

    write_file("one")
    baseline = inotify_fd_count
    sw = EventLoopCompat::StatWatcher.new(path, 30.0) { |_prev, _cur| }
    sw.attach(@loop)
    deleter = EventLoopCompat::TimerWatcher.new(0.2) do
      File.delete(path)
      Dir.rmdir(@dir)
      @dir = nil
    end
    deleter.attach(@loop)
    counts = []
    checker = EventLoopCompat::TimerWatcher.new(0.5) { counts << inotify_fd_count }
    checker.attach(@loop)
    wd = EventLoopCompat::TimerWatcher.new(1.0) { @loop.stop }
    wd.attach(@loop)
    @loop.run

    assert_equal(baseline, counts.last,
                 "the shared inotify fd must be closed when the kernel dropped the last watch")
    assert_nil(@loop.instance_variable_get(:@inotify), "the loop must drop the closed instance")
    assert_equal([], @errors.map { |e| e.class.name })
  end

  # Removing the last watch from another watcher's callback must not
  # close the inotify fd while the inotify fiber is still registered
  # in the selector (io-event raises on that): the fd close must be
  # deferred to the fiber exit, as IOWatcher#close intends.
  def test_last_watch_removed_from_a_callback_closes_fd_safely
    skip "inotify fast path is not supported on this platform" unless EventLoopCompat::Inotify.supported?
    skip "requires /proc/self/fd" unless File.directory?("/proc/self/fd")

    write_file("one")
    baseline = inotify_fd_count
    sw = EventLoopCompat::StatWatcher.new(path, 30.0) { |_prev, _cur| }
    sw.attach(@loop)
    # The detach runs while the loop is running and the inotify fiber
    # is parked in io_wait: the last watch is removed from this other
    # watcher's callback.
    detacher = EventLoopCompat::TimerWatcher.new(0.2) { sw.detach }
    detacher.attach(@loop)
    wd = EventLoopCompat::TimerWatcher.new(0.8) { @loop.stop }
    wd.attach(@loop)
    @loop.run

    assert_equal([], @errors.map { |e| e.class.name })
    assert_equal(baseline, inotify_fd_count,
                 "the fd must be closed after the inotify fiber unregistered")
  end

  def inotify_fd_count
    Dir.children("/proc/self/fd").count do |name|
      begin
        File.readlink(File.join("/proc/self/fd", name)) == "anon_inode:inotify"
      rescue SystemCallError
        # The fd was closed between the listing and the readlink.
        false
      end
    end
  end
end
