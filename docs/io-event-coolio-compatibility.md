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
loaded. The event loop helper loads it when the compat backend is selected, so
a plugin that uses the `Coolio` constants without requiring the gem keeps
working, as it does with the real gem. The `event_loop_compat` entry point does
not load it, because the tests compare the two implementations in one process.

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
timer, IO, socket and stat watcher behavior of one implementation. That
includes the stat watcher baseline: a change made between attaching and running
the loop, detaching and attaching again, keeping the watcher attached across two
runs of the loop, a path that does not exist yet, and removing the watched file.
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
the probe matches the real gem. For each one, why it is kept, what it means for
a plugin, and what a plugin can do instead are written down.

### Re-attaching an attached watcher

`Coolio::Watcher#attach` re-attaches an attached watcher. cool.io raises
`ArgumentError: wrong number of arguments (given 0, expected 1)`.

- Why it is kept: that error is an accident of how the C extension calls the
  loop's `attach` a second time, not a documented contract, and there is no
  second `attach` implementation to reproduce it with.
- Effect on plugins: attaching twice works here and raises with cool.io. Nothing
  in the ecosystem depends on the exception.
- Instead: ask `attached?` before attaching, as plugins already have to do to
  avoid the exception.

### The libev constants of `Coolio::Loop`

`EVBACKEND_*` and `EVFLAG_*` are not defined, and the `:backend`,
`:fork_check` and `:skip_environment` options are accepted but ignored.

- Why it is kept: there is no libev backend to select; io-event uses one
  selector per loop and chooses the mechanism itself.
- Effect on plugins: code reading `Coolio::Loop::EVBACKEND_KQUEUE` gets a
  `NameError`. Nothing in the ecosystem reads them; only the gem's own specs do.
- Instead: do not select a backend.

### `Coolio::TCPSocket::TCPConnectResolver` and asynchronous DNS

The constant is not defined and `Coolio::TCPSocket.connect` resolves the address
synchronously.

- Why it is kept: asynchronous resolution needs a resolver watcher wired to the
  loop; the compatibility layer has no consumer for it, and adding one would be
  new API rather than compatibility.
- Effect on plugins: the first `connect` to a hostname blocks the thread that
  calls it. Subclasses of `Coolio::TCPSocket` work; code that references
  `TCPConnectResolver` or `TCPConnectSocket` by name fails with `NameError`.
- Instead: resolve the address before connecting, or use `IPAddr` literals.

### The attributes of a removed or missing path

Both report exactly one change when the watched file is removed, but the
attributes differ: cool.io reports the attributes the file had before the
removal (its inotify fast path does not re-stat the path), the compatibility
layer reports the attributes of a missing path, which are all zero. For a path
that does not exist when the watcher is attached, the `prev` struct that cool.io
passes contains uninitialized memory.

- Why it is kept: the zeroed attributes are the documented libev polling
  semantics and are the same on every platform; Windows has no inotify, so the
  cool.io values there are already different from Linux. Reproducing the
  cool.io values would mean reproducing uninitialized memory.
- Effect on plugins: a plugin that classifies the event from `prev` and `cur`
  (for example "was the file deleted?") reads different fields. `in_tail` uses
  the callback only as a trigger and does not look at the attributes.
- Instead: treat `cur.mode.zero?` as "the path does not exist", or call
  `File.exist?` in the callback.

### One-shot timers

A one-shot `Coolio::TimerWatcher` is disabled after it fires, so
`Loop#has_active_watchers?` becomes false and `Loop#run` returns. cool.io leaves
the watcher enabled, keeps counting it, and `Loop#run` blocks forever unless a
callback calls `stop`.

- Why it is kept: libev deactivates a one-shot timer when it fires; cool.io
  only fails to lower its Ruby-level counter, so the blocking `run` is a
  bookkeeping bug and not a contract. Reproducing it would make the
  compatibility loop wait forever for an event that can never happen.
- Effect on plugins: a plugin whose last remaining watcher is a fired one-shot
  timer returns from `run` here and hangs with cool.io, so no plugin can depend
  on the hang. A plugin that re-arms a one-shot timer with `enable` gets a
  working timer here and `RuntimeError: already enabled` with cool.io.
- Instead: keep the loop alive with a repeating watcher, which is what the event
  loop helper does with its default watcher, and re-arm with `reset`.

### `attached?` returns `true`

cool.io returns the truthy Integer `0`.

- Why it is kept: `0` is the raw `ev_is_active` value of the C extension leaking
  into Ruby, where every object except `nil` and `false` is true.
- Effect on plugins: `if w.attached?` behaves the same. Comparing the result
  with `==` against `true` or `false` differs.
- Instead: use the truthiness of the result.

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
