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

require 'fluent/plugin_helper/event_loop'
require 'fluent/msgpack_factory'

module Fluent
  module Counter
    # PoC feature flag: pick the cool.io or the EventLoopCompat base
    # classes and loop. The loop instance and the watchers must always
    # come from the same implementation.
    if Fluent::PluginHelper::EventLoop::EVENT_LOOP_BACKEND == :io_event_compat
      LOOP_BASE = EventLoopCompat::Loop
      TCPSERVER_BASE = EventLoopCompat::TCPServer
      TCPSOCKET_BASE = EventLoopCompat::TCPSocket
    else
      LOOP_BASE = Coolio::Loop
      TCPSERVER_BASE = Coolio::TCPServer
      TCPSOCKET_BASE = Coolio::TCPSocket
    end

    class BaseSocket < TCPSOCKET_BASE
      def packed_write(data)
        write pack(data)
      end

      def on_read(data)
        Fluent::MessagePackFactory.msgpack_unpacker.feed_each(data) do |d|
          on_message d
        end
      end

      def on_message(data)
        raise NotImplementedError
      end

      private

      def pack(data)
        Fluent::MessagePackFactory.msgpack_packer.pack(data)
      end
    end
  end
end
