# io-event Coolio compatibility

This document describes the compatibility layer used when
`FLUENTD_EVENT_LOOP_BACKEND=io_event_compat` is set.

## Loading

`lib/cool.io.rb` is a load-path shim for `require 'cool.io'`.

- With `FLUENTD_EVENT_LOOP_BACKEND=io_event_compat`, it loads
  `event_loop_compat` and `event_loop_compat/coolio`.
- Without that environment variable, it loads the real `cool.io` gem by
  absolute path.
- If `Coolio::Loop` is already defined, the shim only accepts the
  compatibility namespace. With the compat backend and the real gem
  loaded first, it raises `LoadError` instead of leaving a mixed
  namespace behind.
- `require 'coolio'` is not intercepted. Under the compat backend it still
  loads the real cool.io alias.

`lib/event_loop_compat/coolio.rb` defines the `Coolio` namespace on top of
`EventLoopCompat`. It refuses to load if the real cool.io extension is already
loaded.

Loading both implementations in one process is not supported in any order:

| Loaded first | Then | Result |
| --- | --- | --- |
| real cool.io | `require 'cool.io'` with the compat backend | `LoadError` from the shim |
| real cool.io | `require 'event_loop_compat/coolio'` | `LoadError` from the namespace |
| compatibility namespace | real cool.io | `TypeError: superclass mismatch for class Coolio::Loop` |

Bundler loads the real gem when it is in the `Gemfile`, so a deployment using
the compat backend must not require the `cool.io` gem.

## Implemented public API

| API | Status | Notes |
| --- | --- | --- |
| `Coolio::VERSION` | Implemented | Reports `1.9.0`. |
| `Cool.io` | Implemented | Returns the `Coolio` module. |
| `Coolio::Loop` | Implemented | Inherits `EventLoopCompat::Loop`. |
| `Coolio::Loop.default` | Implemented | Uses `Thread#_coolio_loop`. |
| `Coolio::Loop#run` | Implemented | Raises when no watchers are attached, returns `false`. |
| `Coolio::Loop#run_once` | Implemented | Returns an approximate event count. |
| `Coolio::Loop#run_nonblock` | Implemented | Calls `run_once(0)`. |
| `Coolio::Loop#stop` | Implemented | Raises when the loop is not running. |
| `Coolio::Loop#has_active_watchers?` | Implemented | Uses active watcher count. |
| `Coolio::Watcher` | Implemented | Base class of the watcher classes; base initialization error is preserved. |
| `Coolio::Watcher#attach` | Implemented | Preserves loop type and attach errors, accepts the loop of the event loop helper. |
| `Coolio::Watcher#detach` | Implemented | Preserves not-attached error. |
| `Coolio::Watcher#enable` | Implemented | Preserves not-attached and already-enabled errors. |
| `Coolio::Watcher#disable` | Implemented | Preserves already-disabled error. |
| `Coolio::IOWatcher` | Implemented | Accepts cool.io string flags. |
| `Coolio::TimerWatcher` | Implemented | Includes `reset`. |
| `Coolio::StatWatcher` | Implemented | Subclass with `on_change`, like real cool.io. |
| `Coolio::StatWatcher::StatInfo` | Implemented | Named `Struct::StatInfo` with the member order of the C extension. |
| `Coolio::AsyncWatcher` | Implemented | Uses an `IO.pipe` like real cool.io. |
| `Coolio::Buffer` | Approximate | Pure Ruby approximation. |
| `Coolio::IO` | Implemented | Uses an internal `Coolio::IO::Watcher`, like real cool.io. |
| `Coolio::Socket` | Implemented | Uses a `Connector` watcher. |
| `Coolio::TCPSocket` | Implemented | Hostname resolution is synchronous. |
| `Coolio::UNIXSocket` | Implemented | Connects synchronously like real cool.io. |
| `Coolio::Listener` | Implemented | Uses `accept_nonblock`. |
| `Coolio::TCPListener` | Implemented | Sets `do_not_reverse_lookup` like real cool.io. |
| `Coolio::UNIXListener` | Implemented | Wraps `UNIXServer`. |
| `Coolio::Server` | Implemented | Validates connection class and arity. |
| `Coolio::TCPServer` | Implemented | Supports port `0` and existing `TCPServer`. |
| `Coolio::UNIXServer` | Implemented | Supports existing `UNIXServer`. |
| `Coolio::DNSResolver` | Implemented | Ported from real cool.io Ruby code. |

## Tested behavior

`test/event_loop_compat/coolio_namespace_probe.rb` checks:

- `Coolio::VERSION`
- `Cool.io`
- `Coolio::Loop` option validation
- `Coolio::Watcher` base initialization error
- `Coolio::Loop#attach` loop type error
- `Coolio::IOWatcher` invalid flag error
- `Coolio::TimerWatcher` reset and detach errors
- `Coolio::Loop#stop`, `run`, and `run_once` errors
- one-shot timer behavior
- `Coolio::AsyncWatcher`
- `Coolio::IOWatcher` readable events
- `Coolio::Buffer` basic behavior
- `Coolio::TCPServer` echo behavior
- class hierarchy checks for socket and server classes

`test/event_loop_compat/test_coolio_namespace.rb` runs that probe in a child
process so the compat `Coolio` namespace does not pollute the test process.

`test/event_loop_compat/coolio_compare_probe.rb` reports the class hierarchy,
`is_a?`/`kind_of?`/`===`, constructor and callback errors, loop return values,
timer, IO, socket and stat watcher behavior of one implementation.
`test/event_loop_compat/test_coolio_compatibility.rb` runs it against the real
cool.io gem and against this repository in child processes and compares the
two reports, so the contracts above are checked against the real gem rather
than against a copy of them written by hand.

`test/event_loop_compat/test_load_order.rb` checks the loading combinations in
the table above.

`test/plugin_helper/test_event_loop_coolio_watchers.rb` attaches timer, IO and
stat watchers to the loop created by the event loop helper, which is what
external plugins do.

## Differences from cool.io

These are the differences the comparison test pins down. Everything else in
the probe matches the real gem.

- Re-attaching an attached watcher re-attaches it. cool.io raises
  `ArgumentError: wrong number of arguments (given 0, expected 1)` because of
  how its C extension handles the second `attach`.
- `Coolio::Loop` does not define the libev `EVBACKEND_*` and `EVFLAG_*`
  constants. There is no libev backend to select.
- `Coolio::TCPSocket` does not define `TCPConnectResolver`; the address is
  resolved synchronously, see `Known gaps`.
- `Coolio::StatWatcher` stats the path when the loop starts, cool.io when the
  watcher is attached. A change made between attaching and running the loop is
  reported by cool.io and missed here.
- A one-shot `Coolio::TimerWatcher` is disabled after it fires, so
  `Loop#run` returns. cool.io leaves it enabled and `Loop#run` blocks forever
  unless a callback stops the loop.
- `attached?` returns `true`. cool.io returns the truthy value `0`.

## Known gaps

- `run_once` event counts are approximate. IO events are counted from the
  selector ready count; timer callbacks increment a counter. This is not
  guaranteed to match libev event counts exactly.
- `Coolio::Buffer` is a pure-Ruby approximation and is not validated against
  the real C extension behavior.
- `Coolio::DNSResolver` is implemented but not directly tested.
- `Coolio::TCPSocket.connect` resolves hostnames synchronously with
  `Addrinfo.getaddrinfo`; real cool.io uses asynchronous DNS resolution.
- `Coolio::Loop` accepts `:skip_environment`, `:fork_check`, and `:backend`
  options for API compatibility, but they do not configure libev behavior.
- `require 'coolio'` is not shimmed. Under the compat backend it loads the real
  cool.io alias and can conflict with the compatibility namespace.
- The concrete Coolio watcher classes inherit `Coolio::Watcher` and get their
  implementation from the `EventLoopCompat` watcher classes by mixing in
  `EventLoopCompat::IOWatcherBehavior`, `EventLoopCompat::TimerWatcherBehavior`
  and `EventLoopCompat::StatWatcherBehavior`. The behavior modules are not
  `Coolio` constants, so `Coolio::Watcher.ancestors` matches the real gem.
  `Coolio::IO` is not a watcher in cool.io, so it stays based on
  `EventLoopCompat::BufferedIO`.
