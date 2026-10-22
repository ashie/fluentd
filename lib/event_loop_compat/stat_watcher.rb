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
# the platform). Like libev, no callback is made at startup: the path is
# stat'ed when the watcher is attached and that only seeds the baseline,
# which is kept while the watcher stays attached. Change detection
# compares all members including ctime.
#
# This implementation works on every platform (including Windows, where
# Coolio cannot use inotify). On Linux it uses an inotify fast path
# (the file itself plus its parent directory, through the per-loop
# shared Inotify instance, like libev) so change detection is
# immediate, matching what libev/cool.io do there; the polling timer
# keeps running as the fallback, exactly like libev's automatic
# interval. On other platforms detection latency is bounded by the
# polling interval. Coolio's default interval (0, "automatic", about 5
# seconds in libev) is kept as the default here as well.
#

require 'event_loop_compat/watcher'
require 'event_loop_compat/inotify'

module EventLoopCompat
  # The behavior of a stat watcher, kept in a module so that the Coolio
  # compatibility namespace (event_loop_compat/coolio.rb) can reuse it on
  # top of Coolio::Watcher, which is required for the Coolio class
  # hierarchy (Coolio::StatWatcher < Coolio::Watcher) to match cool.io.
  # The constants stay on EventLoopCompat::StatWatcher: cool.io defines no
  # constant under Coolio::StatWatcher, and the struct its C extension
  # creates is the top-level Struct::StatInfo.
  module StatWatcherBehavior
    attr_reader :path, :interval

    def initialize(path, interval = nil, &callback)
      interval = interval.nil? ? 0 : Float(interval)
      @path = path
      @interval = interval == 0 ? EventLoopCompat::StatWatcher::DEFAULT_INTERVAL : interval
      @callback = callback
      @handle = nil
      @deadline = nil
      @last = nil
      @inotify = nil
      @wd_file = nil
      @wd_dir = nil
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
      # The baseline was seeded when the watcher was attached; a watcher
      # attached while the loop runs is seeded here instead.
      @last = stat_info if @last.nil?
      @deadline = loop.timers.now + @interval
      schedule_next(loop)
      start_inotify(loop)
    end

    # cool.io (libev ev_stat) stats the path when the watcher is attached,
    # so a change made between attaching and running the loop is reported.
    # Attaching again re-seeds the baseline, as in cool.io.
    def __attached__(loop)
      super
      @last = stat_info
    end

    def __stop_runtime__(loop)
      cancel_handle
      stop_inotify
    end

    # The watcher stays attached when the loop stops, and cool.io keeps
    # comparing against the attributes it read before, so the baseline
    # survives across runs.
    def __run_finished__
      cancel_handle
      stop_inotify
      @deadline = nil
    end

    # Called by the shared Inotify instance for events matching a watch
    # descriptor this watcher registered.
    def __inotify_event__(wd, mask, name)
      relevant = false
      if (mask & Inotify::IN_IGNORED) != 0
        # The kernel dropped the watch (file removed or moved away):
        # update_watches re-adds it when the path exists again.
        @wd_file = nil if wd == @wd_file
        @wd_dir = nil if wd == @wd_dir
        relevant = true
      elsif (mask & Inotify::IN_Q_OVERFLOW) != 0
        relevant = true
      elsif wd == @wd_file
        relevant = true
      elsif wd == @wd_dir && name == File.basename(@path)
        relevant = true
      end
      return unless relevant
      begin
        check_stat
      rescue => e
        @loop.__error__(self, e) if @loop
      end
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
      unless cur == @last
        begin
          on_change(@last, cur)
        rescue => e
          @loop.__error__(self, e) if @loop
        end
        @last = cur
      end
      update_watches if @inotify
    end

    def zero_stat_info
      epoch = Time.at(0)
      EventLoopCompat::StatWatcher::StatInfo.new(epoch, epoch, epoch, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    end

    def stat_info
      st = File.stat(@path)
      mode = st.mode
      if windows? && File.file?(@path)
        mode |= 0666
      end

      blksize = begin
        st.blksize if st.respond_to?(:blksize)
      rescue StandardError
        nil
      end
      blocks = begin
        st.blocks if st.respond_to?(:blocks)
      rescue StandardError
        nil
      end

      EventLoopCompat::StatWatcher::StatInfo.new(
        st.mtime, st.ctime, st.atime, st.dev, st.ino, mode,
        st.nlink, st.uid, st.gid, st.rdev, st.size,
        blksize, blocks)
    rescue SystemCallError
      zero_stat_info
    end

    def windows?
      RUBY_PLATFORM =~ /mswin|mingw|cygwin/
    end

    #
    # inotify fast path (Linux only; the polling timer above stays as
    # the fallback, exactly like libev's ev_stat). The inotify instance
    # is shared per loop, so the fd count does not grow with the number
    # of watched paths.
    #

    def start_inotify(loop)
      @inotify = loop.inotify
      return unless @inotify
      update_watches
    rescue StandardError
      @inotify = nil
    end

    def stop_inotify
      return unless @inotify
      @inotify.remove_watch(self, @wd_file) if @wd_file
      @inotify.remove_watch(self, @wd_dir) if @wd_dir
      @inotify = nil
      @wd_file = nil
      @wd_dir = nil
    end

    def update_watches
      if @inotify.nil? || @inotify.closed?
        # The shared instance closed itself when the kernel dropped the
        # last watch (or on the previous stop): get a fresh one.
        @wd_file = nil
        @wd_dir = nil
        @inotify = @loop && @loop.inotify
      end
      return unless @inotify

      if @wd_dir.nil?
        @wd_dir = @inotify.add_watch(self, File.dirname(@path), Inotify::DIR_WATCH_MASK)
      end

      if File.exist?(@path)
        if @wd_file.nil?
          @wd_file = @inotify.add_watch(self, @path, Inotify::FILE_WATCH_MASK)
        end
      elsif @wd_file
        @inotify.remove_watch(self, @wd_file)
        @wd_file = nil
      end

      # Nothing could be registered (the parent directory is gone and
      # so on): do not keep the shared instance open for a watcher with
      # no watch; the polling timer is the fallback.
      if @inotify.empty?
        @inotify.close
        @inotify = nil
      end
    end
  end

  class StatWatcher < Watcher
    # Same "automatic" default as libev's ev_stat.
    DEFAULT_INTERVAL = 5.0

    # Same name, member order and enclosing class as the struct the
    # cool.io C extension defines (Struct::StatInfo), while keeping the
    # EventLoopCompat::StatWatcher::StatInfo alias used by the tests and
    # by plugins that refer to the struct class.
    if Struct.const_defined?(:StatInfo, false)
      # The real cool.io extension was loaded first and defined the same
      # struct; reuse it instead of warning about a redefinition.
      StatInfo = Struct::StatInfo
    else
      StatInfo = Struct.new(
        "StatInfo",
        :mtime, :ctime, :atime, :dev, :ino, :mode, :nlink,
        :uid, :guid, :rdev, :size, :blksize, :blocks)
    end

    include StatWatcherBehavior
  end
end
