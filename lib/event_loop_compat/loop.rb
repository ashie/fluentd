#
# EventLoopCompat - PoC compatibility layer for cool.io on top of io-event.
#
# The public API intentionally mimics a small subset of Coolio::Loop:
#
#   loop = EventLoopCompat::Loop.new
#   watcher.attach(loop)
#   loop.run(timeout)   # blocks until stop or no active watchers
#   loop.stop           # can be called from another thread
#
# All selector / fiber / timer operations are executed on the event loop
# thread. Watcher operations issued from other threads are queued and
# applied by the event loop thread after waking it up with
# IO::Event::Selector#wakeup.
#

require 'io/event'
require 'io/event/timers'

module EventLoopCompat
  class Loop
    # The io-event selector instance. Only valid while running, and only
    # touched from the event loop thread (except #wakeup).
    attr_reader :selector

    # Called as error_handler.call(watcher, error) when a watcher callback
    # raises. The loop keeps running whatever the handler does.
    attr_accessor :error_handler

    def initialize(error_handler: nil)
      @timers = IO::Event::Timers.new
      @error_handler = error_handler

      @mutex = Mutex.new
      @watchers = []
      @commands = Queue.new

      @selector = nil
      @loop_thread = nil
      @running = false
      @stop_requested = false
    end

    def timers
      @timers
    end

    def running?
      @running
    end

    # All attached watchers. Same meaning as Coolio::Loop#watchers.
    def watchers
      synchronize { @watchers.dup }
    end

    def attach(watcher)
      synchronize do
        return self if @watchers.include?(watcher)
        @watchers << watcher
      end
      watcher.__attached__(self)
      # Runtime resources (timer handles / IO fibers) must be created on
      # the event loop thread. If the loop is not running, run() creates
      # them when it starts.
      defer([:start_runtime, watcher]) if @running
      self
    end

    def detach(watcher)
      removed = synchronize { @watchers.delete(watcher) }
      return self if removed.nil?
      watcher.__detached__
      if @running
        defer([:stop_runtime, watcher])
      else
        watcher.__stop_runtime__(self)
      end
      self
    end

    def enable(watcher)
      return self unless attached_here?(watcher)
      watcher.__enable_flag__
      defer([:start_runtime, watcher]) if @running
      self
    end

    def disable(watcher)
      return self unless attached_here?(watcher)
      watcher.__disable_flag__
      if @running
        defer([:stop_runtime, watcher])
      else
        watcher.__stop_runtime__(self)
      end
      self
    end

    # Run the event loop. +timeout+ is the maximum time to block in each
    # iteration (same meaning as Coolio::Loop#run / libev max_block), so
    # the loop wakes up periodically even when nothing happens.
    #
    # Returns when stop is requested or when no attached watcher is
    # enabled, like Coolio.
    def run(timeout = nil)
      raise "loop already running" if @running

      initial = synchronize { @watchers.dup }
      raise RuntimeError, "no watchers for this loop" if initial.empty?

      @selector = IO::Event::Selector.new(Fiber.current)
      @loop_thread = Thread.current
      @running = true
      @stop_requested = false

      begin
        initial.each do |w|
          w.__start_runtime__(self) if w.attached? && w.enabled?
        end

        while !@stop_requested && active_count > 0
          process_commands
          duration = run_duration(timeout)
          @selector.select(duration)
          @timers.fire
        end
      ensure
        @running = false
        begin
          @selector.close
        rescue => e
          __error__(nil, e)
        end
        @selector = nil
        @loop_thread = nil
        synchronize { @watchers.dup }.each do |w|
          w.__run_finished__
        end
      end

      self
    end

    # Request the loop to stop. Safe to call from any thread and safe to
    # call twice (unlike Coolio#stop which raises when not running).
    # Returns true if a stop request was newly made.
    def stop
      return false unless @running
      @stop_requested = true
      @selector.wakeup if @selector
      true
    end

    def __error__(watcher, error)
      handler = @error_handler
      return unless handler
      begin
        handler.call(watcher, error)
      rescue
        # errors in the error handler are ignored
      end
    end

    private

    def synchronize(&block)
      @mutex.synchronize(&block)
    end

    def attached_here?(watcher)
      synchronize { @watchers.include?(watcher) }
    end

    def active_count
      synchronize { @watchers.count { |w| w.enabled? } }
    end

    def on_loop_thread?
      @loop_thread && Thread.current.equal?(@loop_thread)
    end

    def defer(command)
      @commands << command
      # Wake up the loop only when it can actually be blocked in select.
      # Selector#wakeup is a no-op when the loop is not blocked.
      @selector.wakeup if @selector && !on_loop_thread?
    end

    def process_commands
      until @commands.empty?
        command = begin
          @commands.pop(true)
        rescue ThreadError
          break
        end
        kind, watcher = command
        case kind
        when :start_runtime
          watcher.__start_runtime__(self) if watcher.attached? && watcher.enabled?
        when :stop_runtime
          watcher.__stop_runtime__(self)
        end
      end
    end

    # Never busy-loop: block until the next timer, or until the periodic
    # +timeout+ when given, or forever when neither is given.
    def run_duration(timeout)
      interval = @timers.wait_interval
      duration = timeout
      if interval && (duration.nil? || interval < duration)
        duration = interval
      end
      # A timer may already be due between wait_interval and fire:
      # ::IO.select rejects negative timeouts, so clamp to zero.
      duration && (duration < 0 ? 0.0 : duration)
    end
  end
end
