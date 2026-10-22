#
# Contract tests: EventLoopCompat::StatWatcher#on_change arguments must
# match what the real Coolio::StatWatcher (libev ev_stat) passes.
#
# Run: bundle exec ruby -Ilib -Itest test/event_loop_compat/test_stat_watcher_contract.rb
#
# Observed cool.io / libev behavior (probed against the real gem):
#   - no callback at startup: the first stat only seeds the baseline
#   - a same-file rewrite keeps ino and fires exactly one change event
#   - a removal fires exactly one event
#   - a recreation fires exactly one event with the new attributes
#
# One documented divergence: cool.io's inotify fast path on Linux
# reports the removal with the last known attributes unchanged, while
# the polling path (and libev's documented semantics) report mode == 0.
# The compat watcher always reports mode == 0 so behavior does not
# depend on the platform; the removal pair is therefore not compared
# member by member.
#

require 'test/unit'
require 'tmpdir'
require 'fileutils'

require 'coolio'
require 'event_loop_compat'

class EventLoopCompatStatWatcherContractTest < Test::Unit::TestCase
  INTERVAL = 0.05

  # Same sequence for both implementations (file "one" exists first):
  #   rewrite -> delete -> recreate
  OPS = [
    [0.2, ->(t) { File.open(t, "w") { |f| f.write("two-and-longer") } }],
    [0.4, ->(t) { File.delete(t) }],
    [0.6, ->(t) { File.open(t, "w") { |f| f.write("three") } }],
  ]
  STOP_AT = 0.8

  # Members whose values must be identical across the two
  # implementations for the same file state. ino / mtime / ctime /
  # atime depend on when and where the file was created, so they are
  # only checked for type and internal consistency. blksize / blocks
  # are not compared: the real cool.io extension fills them only when
  # it is built with HAVE_ST_BLKSIZE, which is not the case everywhere.
  STABLE_MEMBERS = [:dev, :mode, :nlink, :uid, :guid, :rdev, :size]

  def setup
    @errors = []
    @dir = Dir.mktmpdir("event-loop-compat-stat-contract")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def path
    File.join(@dir, "watched.txt")
  end

  def reset_file
    FileUtils.rm_f(path)
    File.open(path, "w") { |f| f.write("one") }
  end

  def test_statinfo_members_match_coolio
    reset_file
    cool = capture_coolio.first[1].class
    assert_equal(cool.members, EventLoopCompat::StatWatcher::StatInfo.members,
                 "StatInfo members and order must match cool.io")
  end

  def test_on_change_arguments_match_coolio
    reset_file
    cool = capture_coolio
    reset_file
    compat = capture_compat

    assert_equal(3, cool.size, "cool.io baseline events: #{describe(cool)}")
    assert_equal(cool.size, compat.size, "event count must match cool.io: compat=#{describe(compat)}")

    # event 0 (rewrite): prev and cur describe the same real files
    compare_state(cool[0][0], compat[0][0])
    compare_state(cool[0][1], compat[0][1])
    # a same-file rewrite must keep ino in both implementations
    assert_equal(cool[0][0].ino, cool[0][1].ino, "cool.io: rewrite keeps ino")
    assert_equal(compat[0][0].ino, compat[0][1].ino, "compat: rewrite keeps ino")

    # event 1 (removal): both fire exactly once; the compat watcher
    # follows the documented polling semantics (mode == 0).
    assert_equal(0, compat[1][1].mode, "compat must report removal as mode 0")

    # event 2 (recreation): cur describes the same real file
    compare_state(cool[2][1], compat[2][1])

    # no startup firing in either implementation: the first event is
    # the rewrite, whose prev is the seeded "one" baseline.
    assert_equal(3, cool[0][0].size, "cool.io first event must be the rewrite")
    assert_equal(3, compat[0][0].size, "compat first event must be the rewrite")
  end

  private

  def describe(events)
    events.map { |(p, c)| [p.mode, p.size, c.mode, c.size] }
  end

  def compare_state(cool, compat)
    assert_kind_of(EventLoopCompat::StatWatcher::StatInfo, compat)
    STABLE_MEMBERS.each do |name|
      assert_equal(cool.public_send(name), compat.public_send(name),
                   "member #{name} must match cool.io (cool=#{cool.inspect})")
    end
    [:mtime, :ctime, :atime].each do |name|
      assert_kind_of(Time, cool.public_send(name))
      assert_kind_of(Time, compat.public_send(name))
    end
    assert_kind_of(Integer, compat.ino)
  end

  def capture_compat
    events = []
    loop = EventLoopCompat::Loop.new(error_handler: ->(_w, e) { @errors << e })
    sw = EventLoopCompat::StatWatcher.new(path, INTERVAL) { |prev, cur| events << [prev, cur] }
    sw.attach(loop)
    OPS.each do |at, op|
      tw = EventLoopCompat::TimerWatcher.new(at) { op.call(path) }
      tw.attach(loop)
    end
    wd = EventLoopCompat::TimerWatcher.new(STOP_AT) { loop.stop }
    wd.attach(loop)
    loop.run
    assert_equal([], @errors.map { |e| e.class.name })
    events
  end

  def capture_coolio
    events = []
    loop = Coolio::Loop.new
    sw = stat_watcher_class { |prev, cur| events << [prev, cur] }.new(path, INTERVAL)
    sw.attach(loop)
    OPS.each do |at, op|
      tw = timer_watcher_class { op.call(path) }.new(at, false)
      tw.attach(loop)
    end
    wd = timer_watcher_class { loop.stop }.new(STOP_AT, false)
    wd.attach(loop)
    loop.run
    events
  end

  def stat_watcher_class(&callback)
    Class.new(Coolio::StatWatcher) do
      define_method(:on_change) do |prev, cur|
        callback.call(prev, cur)
      end
    end
  end

  def timer_watcher_class(&callback)
    Class.new(Coolio::TimerWatcher) do
      define_method(:on_timer) do
        callback.call
      end
    end
  end
end
