#
# Fluentd
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

require 'fluent/plugin/input'
require 'fluent/plugin_helper/event_loop'

module Fluent::Plugin
  class TailInput < Fluent::Plugin::Input
    # PoC feature flag: pick the cool.io or the EventLoopCompat base
    # classes. The loop instance and the watchers must always come from
    # the same implementation.
    if Fluent::PluginHelper::EventLoop::EVENT_LOOP_BACKEND == :io_event_compat
      require 'event_loop_compat'
      STAT_WATCHER_BASE = EventLoopCompat::StatWatcher
      TIMER_TRIGGER_BASE = EventLoopCompat::TimerWatcher
    else
      STAT_WATCHER_BASE = Coolio::StatWatcher
      TIMER_TRIGGER_BASE = Coolio::TimerWatcher
    end

    class StatWatcher < STAT_WATCHER_BASE
      def initialize(path, log, &callback)
        @callback = callback
        @log = log
        super(path)
      end

      def on_change(prev, cur)
        @callback.call
      rescue
        @log.error $!.to_s
        @log.error_backtrace
      end
    end

    class TimerTrigger < TIMER_TRIGGER_BASE
      def initialize(interval, log, repeat: true, &callback)
        @log = log
        @callback = callback
        super(interval, repeat)
      end

      def on_timer
        @callback.call
      rescue => e
        @log.error e.to_s
        @log.error_backtrace
      end
    end
  end
end
