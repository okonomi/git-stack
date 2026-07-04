# Snapshot: an unknown subcommand is rejected through main()'s dispatch.
#
# Exercises the command dispatch table and die()'s formatting. Like the
# create-rejects test, the error goes to stderr and exits non-zero as the
# final action, and the merged output is what gets pinned.
require_relative "support/harness"

new_repo("dispatch_unknown")

main(["frobnicate"])
