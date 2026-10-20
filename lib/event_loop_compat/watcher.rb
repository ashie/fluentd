#
# Base class of watchers. The public methods (attach / detach / enable /
# disable / attached? / enabled?) follow the Coolio::Watcher interface.
#
# The __*-prefixed methods are internal hooks called by
# EventLoopCompat::Loop. They are only invoked on the event loop thread,
# or while the loop is not running.
#

require 'event_loop_compat/loop'

module EventLoopCompat
  class Watcher
    attr_reader :loop

    def initialize
      @loop = nil
      @enabled = false
    end

    def attach(loop)
      raise ArgumentError, "watcher already attached" if attached?
      raise ArgumentError, "not an EventLoopCompat::Loop" unless loop.respond_to?(:attach)
      loop.attach(self)
      self
    end

    def detach
      @loop.detach(self) if @loop
      self
    end

    def enable
      @loop.enable(self) if @loop
      self
    end

    def disable
      @loop.disable(self) if @loop
      self
    end

    def attached?
      !@loop.nil?
    end

    def enabled?
      @enabled && !@loop.nil?
    end

    # Coolio-compatible name for the loop accessor
    alias evloop loop

    # internal hooks, not part of the Coolio-compatible API

    def __attached__(loop)
      @loop = loop
      @enabled = true
    end

    def __detached__
      @loop = nil
      @enabled = false
    end

    def __enable_flag__
      @enabled = true
    end

    def __disable_flag__
      @enabled = false
    end

    def __start_runtime__(loop)
    end

    def __stop_runtime__(loop)
    end

    def __run_finished__
    end
  end
end
