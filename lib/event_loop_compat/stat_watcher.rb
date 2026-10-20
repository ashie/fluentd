#
# StatWatcher, a polling-based replacement for Coolio::StatWatcher
# (libev ev_stat, which uses inotify on Linux when available).
#
# StatWatcher.new(path, interval) periodically stats the path and calls
# on_change(prev, cur) when the attributes change, where prev / cur are
# attribute hashes, or nil when the file does not exist. Like libev, a
# watcher attached to an existing file fires once at startup with
# prev = nil.
#
# This implementation works on every platform (including Windows, where
# Coolio cannot use inotify), at the cost of detection latency bounded
# by the polling interval. Coolio's default interval (0, "automatic",
# about 5 seconds in libev) is kept as the default here as well.
#

require 'event_loop_compat/timer_watcher'

module EventLoopCompat
  class StatWatcher < Watcher
    # Same "automatic" default as libev's ev_stat.
    DEFAULT_INTERVAL = 5.0

    attr_reader :path, :interval

    def initialize(path, interval = nil, &callback)
      interval = interval.nil? ? 0 : Float(interval)
      @path = path
      @interval = interval == 0 ? DEFAULT_INTERVAL : interval
      @callback = callback
      @timer = nil
      @last = nil
      super()
    end

    def on_change(prev, cur)
      @callback.call(prev, cur) if @callback
    end

    def __start_runtime__(loop)
      return if @timer
      @last = stat_attrs
      if @last
        begin
          on_change(nil, @last)
        rescue => e
          loop.__error__(self, e)
        end
      end
      @timer = TimerWatcher.new(@interval, true) { check_stat }
      @timer.attach(loop)
    end

    def __stop_runtime__(loop)
      timer = @timer
      @timer = nil
      loop.detach(timer) if timer
    end

    def __run_finished__
      @timer = nil
      @last = nil
    end

    private

    def check_stat
      cur = stat_attrs
      return if cur == @last
      begin
        on_change(@last, cur)
      rescue => e
        @loop.__error__(self, e) if @loop
      end
      @last = cur
    end

    def stat_attrs
      st = File.stat(@path)
      {
        size: st.size,
        mtime: st.mtime.to_f,
        mode: st.mode,
        inode: st.ino,
        nlink: st.nlink,
        uid: st.uid,
        gid: st.gid,
      }
    rescue SystemCallError
      nil
    end
  end
end
