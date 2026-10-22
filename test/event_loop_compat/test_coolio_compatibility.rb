#
# Compares the EventLoopCompat Coolio namespace with the real cool.io
# gem. The checks themselves live in coolio_compare_probe.rb, which is
# run twice in a child process: once against the gem, once against this
# repository. Everything has to match except the divergences listed
# below, which are pinned to the compatibility behaviour so that they
# cannot change without updating this test and the documentation.
#

require 'test/unit'
require 'rbconfig'

class EventLoopCompatCoolioCompatibilityTest < Test::Unit::TestCase
  # observation key => value reported for the compatibility namespace
  KNOWN_DIVERGENCES = {
    # Re-attaching an attached watcher raises a confusing ArgumentError
    # in cool.io; the compatibility layer simply re-attaches.
    "Watcher#attach running loop" => '"no error"',

    # libev backend and flag constants of the C extension. The
    # compatibility loop has no libev backend to select.
    "class Loop" => '"superclass=Object ancestors=Coolio::Loop constants="',

    # cool.io resolves the address of Coolio::TCPSocket.connect
    # asynchronously through Coolio::TCPSocket::TCPConnectResolver, the
    # compatibility layer resolves it synchronously.
    "class TCPSocket" => '"superclass=Coolio::Socket ancestors=Coolio::TCPSocket,Coolio::Socket,Coolio::IO constants=Connector,INPUT_SIZE,PEERADDR_FAILED,TCPConnectSocket,Watcher"',

    # cool.io reports the attributes of the file it had before the
    # removal; the compatibility layer reports the attributes of a
    # missing path, which are all zero.
    "stat removed file" => '"[[0, true]]"',

    # cool.io leaves a one-shot timer enabled after it fires, which
    # makes Loop#run block forever; the compatibility layer disables it.
    "timer one-shot disabled after firing" => 'true',

    # The count of enabled watchers is what the compatibility layer uses
    # to decide whether Loop#run may return.
    "loop has active watchers after one-shot" => 'false',

    # cool.io reports an attached watcher with the truthy value 0.
    "timer one-shot still attached" => 'true',
  }.freeze

  def test_coolio_namespace_matches_real_cool_io
    real = run_probe('real')
    compat = run_probe('compat')

    assert_equal(real.keys, compat.keys, "the two probes reported different observations")

    (real.keys - KNOWN_DIVERGENCES.keys).each do |key|
      assert_equal(real[key], compat[key], "cool.io compatibility mismatch: #{key}")
    end

    KNOWN_DIVERGENCES.each do |key, expected|
      assert_equal(expected, compat[key], "undocumented change in the compatibility behaviour: #{key}")
      assert_not_equal(expected, real[key], "#{key} is not a divergence anymore")
    end
  end

  private

  def run_probe(backend)
    probe = File.expand_path('coolio_compare_probe.rb', __dir__)
    cmd = [RbConfig.ruby]
    cmd << '-Ilib' if backend == 'compat'
    cmd << probe << backend

    # The parent process may already have selected a backend; the child
    # has to be told explicitly which one it is measuring.
    env = { 'FLUENTD_EVENT_LOOP_BACKEND' => backend == 'compat' ? 'io_event_compat' : nil }

    output = IO.popen([env, *cmd], err: [:child, :out], &:read)
    raise "cool.io #{backend} probe failed:\n#{output}" unless $?.success?

    output.each_line.map { |line| line.chomp.split("\t", 2) }.to_h
  end
end
