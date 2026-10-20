#
# StatWatcher, a polling-based replacement for Coolio::StatWatcher
# (libev ev_stat, which uses inotify on Linux when available).
#
# StatWatcher.new(path, interval) periodically stats the path and calls
# on_change(prev, cur) when the attributes change. prev / cur are
# StatInfo structs with the same members as the one cool.io passes
# (mtime, ctime, atime, dev, ino, mode, nlink, uid, guid, rdev, size,
# blksize, blocks; "guid" carries the gid, as in cool.io). A missing
# file is reported as a StatInfo with mode == 0, the documented libev
# polling semantics (cool.io's inotify fast path on Linux instead
# reports a removal with the last known attributes unchanged; we follow
# the deterministic polling semantics so behavior does not depend on
# the platform). Like libev, no callback is made at startup: the first
# stat only seeds the baseline. Change detection compares all members
# including ctime.
#
# This implementation works on every platform (including Windows, where
# Coolio cannot use inotify), at the cost of detection latency bounded
# by the polling interval. Coolio's default interval (0, "automatic",
# about 5 seconds in libev) is kept as the default here as well.
#

require 'event_loop_compat/watcher'

module EventLoopCompat
  class StatWatcher < Watcher
    # Same "automatic" default as libev's ev_stat.
    DEFAULT_INTERVAL = 5.0

    # Same name and member order as the cool.io C extension defines.
    StatInfo = Struct.new(
      :mtime, :ctime, :atime, :dev, :ino, :mode, :nlink,
      :uid, :guid, :rdev, :size, :blksize, :blocks)

    attr_reader :path, :interval

    def initialize(path, interval = nil, &callback)
      interval = interval.nil? ? 0 : Float(interval)
      @path = path
      @interval = interval == 0 ? DEFAULT_INTERVAL : interval
      @callback = callback
      @handle = nil
      @deadline = nil
      @last = nil
      super()
    end

    def on_change(prev, cur)
      @callback.call(prev, cur) if @callback
    end

    # The polling timer is owned directly by this watcher (not attached
    # to the Loop as a separate watcher), so it cannot outlive the
    # watcher across runs or inflate the loop's watcher set.
    def __start_runtime__(loop)
      return if @handle
      # Like libev, the first stat only seeds the baseline: no callback.
      @last = stat_info
      @deadline = loop.timers.now + @interval
      schedule_next(loop)
    end

    def __stop_runtime__(loop)
      cancel_handle
    end

    def __run_finished__
      cancel_handle
      @deadline = nil
      @last = nil
    end

    private

    def schedule_next(loop)
      @handle = loop.timers.schedule(@deadline, method(:fire_check))
    end

    def cancel_handle
      @handle.cancel! if @handle
      @handle = nil
    end

    def fire_check(now)
      @handle = nil
      return unless enabled?

      begin
        check_stat
      rescue => e
        @loop.__error__(self, e) if @loop
      end

      if enabled?
        @deadline += @interval
        # Do not try to catch up missed firings after a long stall.
        @deadline = now + @interval if @deadline <= now
        schedule_next(@loop)
      end
    end

    def check_stat
      cur = stat_info
      return if cur == @last
      begin
        on_change(@last, cur)
      rescue => e
        @loop.__error__(self, e) if @loop
      end
      @last = cur
    end

    def zero_stat_info
      epoch = Time.at(0)
      StatInfo.new(epoch, epoch, epoch, 0, 0, 0, 0, 0, 0, 0, 0, nil, nil)
    end

    def stat_info
      st = File.stat(@path)
      # cool.io 1.9.0 never fills blksize / blocks (its extension does
      # not define HAVE_ST_BLKSIZE), so they stay nil here as well.
      StatInfo.new(
        st.mtime, st.ctime, st.atime, st.dev, st.ino, st.mode,
        st.nlink, st.uid, st.gid, st.rdev, st.size,
        nil, nil)
    rescue SystemCallError
      zero_stat_info
    end
  end
end
