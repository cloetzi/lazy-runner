# syntax=docker/dockerfile:1

# The Ruby version comes from .ruby-version, the single source of truth:
#   docker build --build-arg RUBY_VERSION="$(cat .ruby-version)" .
# The release workflow also passes APP_VERSION (release-please's version) and
# APP_COMMIT (the sha built), which Settings and /api/version show; without
# them the image says it is a dev build.
ARG RUBY_VERSION

FROM ruby:${RUBY_VERSION}-slim AS build
RUN apt-get update -qq && apt-get install -y --no-install-recommends build-essential && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT=development:test BUNDLE_PATH=/usr/local/bundle
COPY Gemfile Gemfile.lock ./
RUN bundle install && rm -rf /usr/local/bundle/cache

FROM ruby:${RUBY_VERSION}-slim
WORKDIR /app
ENV RAGE_ENV=production BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT=development:test BUNDLE_PATH=/usr/local/bundle
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY . .
RUN useradd --system --uid 1000 --home /app app && mkdir -p storage log && chown -R app storage log
# Last, so a new version or commit reuses every layer above.
ARG APP_VERSION=dev
ARG APP_COMMIT=
ENV APP_VERSION=${APP_VERSION} APP_COMMIT=${APP_COMMIT}
USER app
VOLUME /app/storage
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s CMD ruby -rnet/http -e 'exit Net::HTTP.get_response(URI("http://localhost:3000/api/version")).is_a?(Net::HTTPSuccess)'
CMD ["bundle", "exec", "rage", "s", "-e", "production", "-b", "0.0.0.0", "-p", "3000"]
