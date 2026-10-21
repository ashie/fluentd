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
# Coolio cannot use inotify). On Linux it uses an inotify fast path
# (the file itself plus its parent directory, through raw syscalls) so
# change detection is immediate, matching what libev/cool.io do there;
# the polling timer keeps running as the fallback, exactly like libev's
# automatic interval. On other platforms detection latency is bounded by
# the polling interval. Coolio's default interval (0, "automatic",
# about 5 seconds in libev) is kept as the default here as well.
#

require 'fiddle'

require 'event_loop_compat/watcher'
require 'event_loop_compat/io_watcher'

module EventLoopCompat
  class StatWatcher < Watcher
    # Same "automatic" default as libev's ev_stat.
    DEFAULT_INTERVAL = 5.0

    # Same name and member order as the cool.io C extension defines.
    StatInfo = Struct.new(
      :mtime, :ctime, :atime, :dev, :ino, :mode, :nlink,
      :uid, :guid, :rdev, :size, :blksize, :blocks)

    # inotify event masks (uapi linux/inotify.h)
    IN_MODIFY = 0x00000002
    IN_ATTRIB = 0x00000004
    IN_MOVED_FROM = 0x00000040
    IN_MOVED_TO = 0x00000080
    IN_CREATE = 0x00000100
    IN_DELETE = 0x00000200
    IN_DELETE_SELF = 0x00000400
    IN_MOVE_SELF = 0x00000800
    IN_Q_OVERFLOW = 0x00004000
    IN_IGNORED = 0x00008000
    IN_ONLYDIR = 0x00100000
    # inotify_init1 flags (O_NONBLOCK / O_CLOEXEC)
    IN_NONBLOCK = 0x00000800
    IN_CLOEXEC = 0x00080000

    FILE_WATCH_MASK = IN_ATTRIB | IN_MODIFY | IN_DELETE_SELF | IN_MOVE_SELF
    DIR_WATCH_MASK = IN_CREATE | IN_MOVED_TO | IN_MOVED_FROM | IN_DELETE | IN_ONLYDIR

    # libc inotify bindings through Fiddle (stdlib). Kernel#syscall is
    # deprecated and unsafe, and Ruby has no inotify bindings otherwise.
    # Returns nil on platforms without inotify (macOS, Windows), where
    # the polling timer is used alone.
    def self.inotify_functions
      return @inotify_functions if defined?(@inotify_functions)
      @inotify_functions = begin
        libc = Fiddle.dlopen(nil)
        {
          init1: Fiddle::Function.new(libc['inotify_init1'],
                                      [Fiddle::TYPE_INT], Fiddle::TYPE_INT),
          add_watch: Fiddle::Function.new(libc['inotify_add_watch'],
                                          [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_UINT],
                                          Fiddle::TYPE_INT),
          rm_watch: Fiddle::Function.new(libc['inotify_rm_watch'],
                                         [Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT),
        }
      rescue LoadError, RuntimeError
        nil
      end
    end

    attr_reader :path, :interval

    def initialize(path, interval = nil, &callback)
      interval = interval.nil? ? 0 : Float(interval)
      @path = path
      @interval = interval == 0 ? DEFAULT_INTERVAL : interval
      @callback = callback
      @handle = nil
      @deadline = nil
      @last = nil
      @inotify_io = nil
      @inotify_watcher = nil
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
      # Like libev, the first stat only seeds the baseline: no callback.
      @last = stat_info
      @deadline = loop.timers.now + @interval
      schedule_next(loop)
      start_inotify(loop)
    end

    def __stop_runtime__(loop)
      cancel_handle
      stop_inotify
    end

    def __run_finished__
      cancel_handle
      stop_inotify
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
      unless cur == @last
        begin
          on_change(@last, cur)
        rescue => e
          @loop.__error__(self, e) if @loop
        end
        @last = cur
      end
      update_watches if @inotify_io
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

    #
    # inotify fast path (Linux only; the polling timer above stays as
    # the fallback, exactly like libev's ev_stat)
    #

    def start_inotify(loop)
      functions = self.class.inotify_functions
      return unless functions
      fd = functions[:init1].call(IN_NONBLOCK | IN_CLOEXEC)
      return if fd < 0
      @inotify_io = IO.for_fd(fd)
      update_watches
      if @wd_file.nil? && @wd_dir.nil?
        # Nothing can be watched yet (no file, no parent directory):
        # rely on the polling timer.
        stop_inotify
        return
      end
      @inotify_watcher = IOWatcher.new(@inotify_io, :r) { drain_inotify }
      @inotify_watcher.attach(loop)
    rescue StandardError, SystemCallError
      stop_inotify
    end

    def stop_inotify
      if @inotify_watcher
        @inotify_watcher.close
        @inotify_watcher = nil
      elsif @inotify_io && !@inotify_io.closed?
        @inotify_io.close
      end
      @inotify_io = nil
      @wd_file = nil
      @wd_dir = nil
    end

    def update_watches
      functions = self.class.inotify_functions
      return unless functions
      return if @inotify_io.nil? || @inotify_io.closed?

      if @wd_dir.nil?
        wd = functions[:add_watch].call(fileno, File.dirname(@path), DIR_WATCH_MASK)
        @wd_dir = wd if wd >= 0
      end

      if File.exist?(@path)
        if @wd_file.nil?
          wd = functions[:add_watch].call(fileno, @path, FILE_WATCH_MASK)
          @wd_file = wd if wd >= 0
        end
      elsif @wd_file
        functions[:rm_watch].call(fileno, @wd_file)
        @wd_file = nil
      end
    end

    def fileno
      @inotify_io.fileno
    end

    def drain_inotify
      begin
        data = @inotify_io.read_nonblock(4096)
      rescue EOFError
        return
      rescue IO::WaitReadable, Errno::EAGAIN
        return
      end
      return if data.nil? || data.empty?
      relevant = parse_inotify_events(data)
      return unless relevant
      begin
        check_stat
      rescue => e
        @loop.__error__(self, e) if @loop
      end
    end

    # struct inotify_event { int wd; uint32 mask, cookie, len; char name[]; }
    def parse_inotify_events(data)
      relevant = false
      basename = File.basename(@path)
      pos = 0
      while pos + 16 <= data.bytesize
        wd, mask, _cookie, len = data[pos, 16].unpack('l L l L')
        pos += 16
        name = nil
        if len > 0
          name = data[pos, len].to_s.split("\x00", 2).first
          pos += len
        end
        if (mask & IN_IGNORED) != 0
          # The kernel dropped the watch (file removed or moved away):
          # re-added by update_watches when the path exists again.
          @wd_file = nil if wd == @wd_file
          relevant = true
        elsif (mask & IN_Q_OVERFLOW) != 0
          relevant = true
        elsif wd == @wd_file
          relevant = true
        elsif wd == @wd_dir && name == basename
          relevant = true
        end
      end
      relevant
    end
  end
end
