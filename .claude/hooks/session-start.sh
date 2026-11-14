#!/bin/bash
# Prepares a Claude Code cloud session to run the tests natively: Ruby from
# .ruby-version, the gems, Node from .node-version and node_modules.
#
# The cloud image has no Ruby 4, so Ruby is built from the ruby-lang.org source
# into /opt/ruby-<version>. Where the environment blocks ruby-lang.org, it is
# copied out of the official Docker image instead (the Debian bookworm variant,
# whose glibc is older than the host's); that Ruby looks for its standard
# library under the image's prefix, /usr/local/lib/ruby, which is linked to it.
# Each step is skipped when its result is already there, so a resumed or cached
# session starts in seconds.
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}"

ruby_version="$(cat .ruby-version)"
ruby_prefix="/opt/ruby-${ruby_version}"
node_major="$(cat .node-version)"
node_prefix="/opt/node${node_major}"

log() { echo "session-start: $*" >&2; }

start_docker() {
  docker info >/dev/null 2>&1 && return
  log "starting dockerd"
  (setsid dockerd >/tmp/dockerd.log 2>&1 &)
  for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && started_docker=1 && return
    sleep 1
  done
  log "dockerd did not start, see /tmp/dockerd.log"
  exit 1
}

stop_docker() {
  [ -n "${started_docker:-}" ] || return 0
  pkill -x dockerd || true
}

install_ruby() {
  if [ -x "${ruby_prefix}/bin/ruby" ] && "${ruby_prefix}/bin/ruby" -e 'exit 0' 2>/dev/null; then
    return
  fi
  build_ruby || copy_ruby
}

build_ruby() {
  local base="https://cache.ruby-lang.org/pub/ruby"
  local tarball="ruby-${ruby_version}.tar.gz" sha256
  # index.txt lists every release: name, url, sha1, sha256, sha512.
  sha256="$(curl -fsSL "${base}/index.txt" 2>/dev/null | awk -v url="/${tarball}" '(i = index($2, url)) > 0 && i == length($2) - length(url) + 1 { print $4 }')" || true
  if [ -z "${sha256}" ]; then
    log "can't reach ${base}"
    return 1
  fi
  log "building Ruby ${ruby_version} from source"
  local staging
  staging="$(mktemp -d)"
  if curl -fsSL "${base}/${ruby_version%.*}/${tarball}" -o "${staging}/${tarball}" &&
    echo "${sha256}  ${staging}/${tarball}" | sha256sum -c --quiet - &&
    tar -xzf "${staging}/${tarball}" -C "${staging}" &&
    (
      cd "${staging}/ruby-${ruby_version}" &&
        ./configure --prefix="${ruby_prefix}" --disable-install-doc >/dev/null &&
        make -j"$(nproc)" >/dev/null &&
        make install >/dev/null
    ); then
    rm -rf "${staging}"
    return 0
  fi
  log "building Ruby failed"
  rm -rf "${staging}" "${ruby_prefix}"
  return 1
}

copy_ruby() {
  start_docker
  local image="ruby:${ruby_version}-slim-bookworm"
  # Docker Hub rate-limits the shared egress; Google's mirror has the same images.
  if ! docker pull -q "${image}" >/dev/null 2>&1; then
    image="mirror.gcr.io/library/${image}"
    docker pull -q "${image}" >/dev/null
  fi
  log "copying Ruby ${ruby_version} out of ${image}"
  local container staging
  container="$(docker create "${image}")"
  staging="$(mktemp -d)"
  docker export "${container}" | tar -x -C "${staging}" usr/local/bin usr/local/include usr/local/lib
  docker rm "${container}" >/dev/null
  stop_docker
  rm -rf "${ruby_prefix}"
  mv "${staging}/usr/local" "${ruby_prefix}"
  rm -rf "${staging}"
  # The image's scripts start with #!/usr/local/bin/ruby, which on the host is
  # another Ruby.
  sed -i "1s|^#!/usr/local/bin/ruby|#!${ruby_prefix}/bin/ruby|" "${ruby_prefix}"/bin/*
  link_ruby
}

link_ruby() {
  local stdlib="/usr/local/lib/ruby"
  if [ -e "${stdlib}" ] && [ ! -L "${stdlib}" ]; then
    log "${stdlib} exists and is not a link; leaving it alone"
    exit 1
  fi
  ln -sfn "${ruby_prefix}/lib/ruby" "${stdlib}"
  echo "${ruby_prefix}/lib" > /etc/ld.so.conf.d/lazy-runner-ruby.conf
  ldconfig
}

install_node() {
  [ -x "${node_prefix}/bin/node" ] && return
  local base="https://nodejs.org/dist/latest-v${node_major}.x"
  local sums tarball
  sums="$(curl -fsSL "${base}/SHASUMS256.txt")"
  tarball="$(awk '/linux-x64\.tar\.xz$/ { print $2 }' <<<"${sums}")"
  log "installing ${tarball}"
  local staging
  staging="$(mktemp -d)"
  curl -fsSL "${base}/${tarball}" -o "${staging}/${tarball}"
  (cd "${staging}" && grep " ${tarball}\$" <<<"${sums}" | sha256sum -c --quiet -)
  mkdir -p "${node_prefix}"
  tar -xJf "${staging}/${tarball}" -C "${node_prefix}" --strip-components=1
  rm -rf "${staging}"
}

install_ruby
install_node

# UTF-8 as in the official images: Ruby reads files in the locale's encoding,
# and the image defaults to US-ASCII.
export PATH="${ruby_prefix}/bin:${node_prefix}/bin:${PATH}" LANG=C.UTF-8
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"${ruby_prefix}/bin:${node_prefix}/bin:\$PATH\" LANG=C.UTF-8" >> "${CLAUDE_ENV_FILE}"
fi

export BUNDLE_SILENCE_ROOT_WARNING=1 npm_config_update_notifier=false
bundle check >/dev/null 2>&1 || bundle install --jobs 4 --quiet
# npm install rather than npm ci: it keeps an existing node_modules.
npm install --no-audit --no-fund --loglevel=error

# The image comes with a Chromium for its own Playwright, which may be another
# revision than package.json's Playwright expects. Download the expected one
# where the environment allows the browser hosts; where it doesn't, alias the
# installed one under that name: a few revisions apart it drives the same.
prepare_browsers() {
  local installed="${PLAYWRIGHT_BROWSERS_PATH:-}" own="/opt/pw-browsers-lazy-runner"
  local revision
  revision="$(node -p 'require("./node_modules/playwright-core/browsers.json").browsers.find(b => b.name === "chromium").revision')"
  [ -d "${installed}/chromium-${revision}" ] && return
  if [ ! -e "${own}/chromium-${revision}" ]; then
    rm -rf "${own}"
    if PLAYWRIGHT_BROWSERS_PATH="${own}" npx --no-install playwright install chromium >/dev/null 2>&1; then
      log "downloaded Chromium ${revision} for Playwright"
    else
      local have
      have="$(find "${installed}" -maxdepth 1 -name 'chromium-[0-9]*' -printf '%f\n' 2>/dev/null | sort -t- -k2 -n | tail -1)"
      have="${have#chromium-}"
      [ -n "${have}" ] || { log "no Chromium for Playwright; e2e tests won't run"; return 0; }
      log "Chromium download blocked; aliasing ${have} as ${revision} for Playwright"
      rm -rf "${own}"
      mkdir -p "${own}"
      ln -s "${installed}"/* "${own}/"
      ln -s "${installed}/chromium-${have}" "${own}/chromium-${revision}"
      ln -s "${installed}/chromium_headless_shell-${have}" "${own}/chromium_headless_shell-${revision}"
    fi
  fi
  [ -n "${CLAUDE_ENV_FILE:-}" ] && echo "export PLAYWRIGHT_BROWSERS_PATH=\"${own}\"" >> "${CLAUDE_ENV_FILE}"
  return 0
}
prepare_browsers

log "ready: $(ruby -v), node $(node -v)"
