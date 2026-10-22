#
# The Coolio compatibility namespace and the real cool.io extension
# cannot be loaded in the same process. Run the standalone probe in a
# child process so this test can coexist with the other event-loop
# tests.
#

require 'test/unit'
require 'rbconfig'

class EventLoopCompatCoolioNamespaceTest < Test::Unit::TestCase
  def test_coolio_namespace_probe
    probe = File.expand_path('coolio_namespace_probe.rb', __dir__)
    output = IO.popen([RbConfig.ruby, '-Ilib', probe, err: [:child, :out]], &:read)

    assert_equal(0, $?.exitstatus, "cool.io namespace probe failed:\n#{output}")
    assert_equal('OK', output.strip)
  end
end
