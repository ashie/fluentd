#
# EventLoopCompat: a proof-of-concept Coolio-compatible event loop layer
# implemented on top of the low-level selector of the io-event gem.
#
# This is NOT a part of Fluentd. It is an independent namespace used to
# evaluate whether io-event can replace cool.io in Fluentd.
#

require 'event_loop_compat/loop'
require 'event_loop_compat/timer_watcher'
require 'event_loop_compat/io_watcher'
require 'event_loop_compat/inotify'
require 'event_loop_compat/buffered_io'
require 'event_loop_compat/socket'
require 'event_loop_compat/stat_watcher'
