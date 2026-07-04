# Snapshot: sh() wraps an argument in single quotes for safe shell use.
#
# Inputs deliberately avoid an embedded single quote: git-stack's escape for
# that case relies on a gsub backreference quirk that CRuby and Spinel resolve
# differently, so a parity snapshot cannot cover it.
require_relative "support/harness"

puts sh("simple")
puts sh("two words")
puts sh("semi;and&pipe|dollar$star*")
puts sh("--looks-like-a-flag")
puts sh("")
