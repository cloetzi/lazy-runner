# frozen_string_literal: true

# The largest request body the server takes, in megabytes (Iodine counts in
# whole ones; its default is 50). The app's biggest writes, a workout's whole
# structure or a burst of queued sets, are a few kilobytes, and sign-in parses
# its body before the throttle counts the attempt, so anything bigger is
# turned away before it is read.
Iodine::DEFAULT_SETTINGS[:max_body] = 1
