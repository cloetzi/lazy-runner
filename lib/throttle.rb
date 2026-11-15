# Counts attempts in a sliding window, in this process (the server runs one
# worker). Sign-in hashes every password with Argon2, two at a time
# (lib/hashing.rb), so attempts are capped per key (a username, an account) and,
# where it is given, in total, before Rodauth sees them. Per-IP limits would
# only see the proxy in front. A total is shared by everyone who counts
# against it, so lib/auth/throttles.rb keeps one only where an anonymous stream of
# attempts can't spend what real users need (#207). Each key takes room until
# its attempts leave the window, so the table holds at most `max_keys`: past
# that, a new key takes the place of the one added longest ago. A flood of
# made-up usernames can then forget a real one's attempts, never refuse it;
# guessing a password stays bounded by the account lockout.
class Throttle
  Limit = Data.define(:attempts, :seconds)

  def initialize(per_key:, total: nil, max_keys: 10_000, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @per_key = per_key
    @total = total
    @max_keys = max_keys
    @clock = clock
    @hits = Hash.new { |hash, key| hash[key] = [] }
  end

  # Records an attempt for the key, unless it is over a limit. Returns the
  # seconds to wait when it is, else nil.
  def hit(key)
    now = @clock.call
    sweep(now)
    key = key.to_s.downcase
    @hits.delete(@hits.each_key.find { it != :total }) if @hits.size >= @max_keys && !@hits.key?(key)

    wait = [(over(:total, @total, now) if @total), over(key, @per_key, now)].compact.max
    return wait if wait

    @hits[:total] << now if @total
    @hits[key] << now
    nil
  end

  def reset!
    @hits.clear
  end

  def size = @hits.size

  private

  # Forgets keys whose attempts have all left the window, once a window, so
  # a stream of made-up usernames doesn't keep growing the table.
  def sweep(now)
    return if @swept_at && now - @swept_at < @per_key.seconds

    @swept_at = now
    @hits.delete_if { |key, hits| hits.empty? || hits.last <= now - (key == :total ? @total : @per_key).seconds }
  end

  def over(key, limit, now)
    hits = @hits[key]
    hits.shift while hits.any? && hits.first <= now - limit.seconds
    @hits.delete(key) if hits.empty?
    return if hits.size < limit.attempts

    (hits.first + limit.seconds - now).ceil.clamp(1, limit.seconds)
  end
end
