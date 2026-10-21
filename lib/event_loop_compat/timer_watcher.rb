#
# TimerWatcher, compatible with the subset of Coolio::TimerWatcher that
# Fluentd uses: TimerWatcher.new(interval, repeats) and the on_timer
# callback. A block can be given as a shortcut for the callback
# (block.call(self)), or subclasses can override #on_timer.
#
# Timing is based on IO::Event::Timers, which uses
# Process::CLOCK_MONOTONIC. A repeating timer keeps a fixed schedule
# (deadline + interval), and skips missed intervals after a long stall.
#

require 'event_loop_compat/watcher'

module EventLoopCompat
  class TimerWatcher < Watcher
    attr_reader :interval, :repeats

    def initialize(interval, repeats = false, &callback)
      interval = interval.to_f
      # libev (and therefore cool.io) accepts interval 0: the timer
      # fires as soon as possible, and repeat == 0 means one-shot.
      raise ArgumentError, "interval must not be negative" unless interval >= 0
      @interval = interval
      @repeats = repeats && interval > 0
      @callback = callback
      @handle = nil
      @deadline = nil
      super()
    end

    def on_timer
      @callback.call(self) if @callback
    end

    def __start_runtime__(loop)
      return if @handle
      @deadline = loop.timers.now + @interval
      schedule_next(loop)
    end

    def __stop_runtime__(loop)
      cancel_handle
    end

    def __run_finished__
      cancel_handle
      @deadline = nil
    end

    private

    def schedule_next(loop)
      @handle = loop.timers.schedule(@deadline, method(:fire_timer))
    end

    def cancel_handle
      @handle.cancel! if @handle
      @handle = nil
    end

    def fire_timer(now)
      @handle = nil
      return unless enabled?

      begin
        on_timer
      rescue => e
        @loop.__error__(self, e) if @loop
      end

      if @repeats && enabled?
        @deadline += @interval
        # Do not try to catch up missed firings after a long stall.
        @deadline = now + @interval if @deadline <= now
        schedule_next(@loop)
      else
        # A one-shot timer is not re-armed: it stays attached but stops
        # firing, and the loop can exit when nothing else is active.
        __disable_flag__
      end
    end
  end
end
