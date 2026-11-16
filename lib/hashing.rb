# frozen_string_literal: true

# Runs Argon2 on a thread of its own. The server runs one worker, whose
# requests are fibers on one thread: a hash there (about 100 ms of CPU in
# C) would hold up every other request until it is done, which a request
# made alongside a sign-in could time to tell a real account from a made-up
# one. Here the fiber waits for the hash as for any I/O, and the others go
# on. The argon2 gem lets go of Ruby's lock while it hashes.
#
# Two threads, so two hashes at once at most: each takes Argon2's 64 MiB
# while it runs, and the throttles in front bound how many wait. A sign-in
# that only waits instead of hashing (an unknown username past the dummy
# hashes' budget) waits on a thread here too, so it queues like a hash.
#
# The caller waits on a pipe, which the fiber scheduler watches like any
# socket: the answer can't come before anyone listens for it.
module Hashing
  THREADS = 2

  @mutex = Mutex.new

  def self.run(&work)
    reader, writer = IO.pipe
    answer = []
    jobs << [work, writer, answer]
    reader.read(1)
    ok, value = answer
    ok ? value : raise(value)
  ensure
    reader&.close
  end

  # The queue and its threads, made again in a forked process, which keeps
  # neither the threads nor anyone waiting on them.
  def self.jobs
    @mutex.synchronize do
      next @jobs if @pid == Process.pid

      @pid = Process.pid
      @jobs = Thread::Queue.new
      THREADS.times { Thread.new(@jobs) { work(it) } }
      @jobs
    end
  end

  def self.work(jobs)
    while (job = jobs.pop)
      work, writer, answer = job
      job = nil # nothing of the job (a password, a request) outlives it
      begin
        answer.push(true, work.call)
      rescue Exception => error # rubocop:disable Lint/RescueException -- anything at all: the caller re-raises it, the worker carries on
        answer.push(false, error)
      end
      work = answer = nil
      writer.write(".")
      writer.close
      writer = nil
    end
  end
end
