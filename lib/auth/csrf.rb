module Auth
  # Writes made with the session cookie must come from the app's own pages:
  # a same-origin request (Sec-Fetch-Site, or else Origin), with a JSON body.
  # SameSite=Lax alone would let another app on a sibling subdomain post a
  # form here, since the browser counts that as the same site. A write with
  # an API token carries no cookie, so it has nothing for another site to
  # ride on and isn't checked (lib/auth/gate.rb).
  module Csrf
    UNSAFE = %w[POST PUT PATCH DELETE].freeze
    # The refusals, by reason.
    REFUSED = "Refused: the request didn't come from this app".freeze
    NOT_JSON = "Send the body as application/json".freeze

    def self.unsafe?(request) = UNSAFE.include?(request.request_method)

    # Why the write is refused, nil if it isn't.
    def self.refusal(request)
      site = request.env["HTTP_SEC_FETCH_SITE"]
      origin = request.env["HTTP_ORIGIN"]
      same =
        if site then site == "same-origin"
        elsif origin then origin == request.base_url
        else false
        end
      return REFUSED unless same

      has_body = request.env["IODINE_HAS_BODY"] || request.content_length.to_i.positive?
      return NOT_JSON if has_body && !request.media_type.to_s.match?(%r{\Aapplication/json\z}i)

      nil
    end
  end
end
