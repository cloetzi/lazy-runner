# Changelog

## [0.10.0](https://github.com/cloetzi/lazy-runner/compare/v0.9.1...v0.10.0) (2026-11-21)


### Features

* **check-ins:** check in on Today, the Calendar and Coach ([#44](https://github.com/cloetzi/lazy-runner/issues/44)) ([37a4cad](https://github.com/cloetzi/lazy-runner/commit/37a4cad8d3999dc9b59728c6b0c8329ab21df384))
* **check-ins:** log last night and how the day felt, for the coach ([#41](https://github.com/cloetzi/lazy-runner/issues/41)) ([a19b2b7](https://github.com/cloetzi/lazy-runner/commit/a19b2b7f5cbecd442c517c3ce070346b5e3468fb))


### Bug Fixes

* **a11y:** name the undo button by the words it shows ([#42](https://github.com/cloetzi/lazy-runner/issues/42)) ([34c93d4](https://github.com/cloetzi/lazy-runner/commit/34c93d46cc1c8afa08cb1baa87fe66d61b4cbc11)), closes [#28](https://github.com/cloetzi/lazy-runner/issues/28)

## [0.9.1](https://github.com/cloetzi/lazy-runner/compare/v0.9.0...v0.9.1) (2026-11-21)


### Bug Fixes

* **deps:** update rodauth for GHSA-jv3v-q542-9c26, finish the Ruby group ([#37](https://github.com/cloetzi/lazy-runner/issues/37)) ([3dbdfdc](https://github.com/cloetzi/lazy-runner/commit/3dbdfdc4449ed86b9556f06ca21d93aa016f444d))
* **deps:** update ruby ([#35](https://github.com/cloetzi/lazy-runner/issues/35)) ([caf7879](https://github.com/cloetzi/lazy-runner/commit/caf7879ddd1e138f90f3438dfb8df02629aaba18))

## [0.9.0](https://github.com/cloetzi/lazy-runner/compare/v0.8.0...v0.9.0) (2026-11-16)


### Features

* **coach:** give news, the coach's reading, goals and notes their own look ([#27](https://github.com/cloetzi/lazy-runner/issues/27)) ([6138d66](https://github.com/cloetzi/lazy-runner/commit/6138d66e5d19174a67da886ab88f36c2b92a5c52)), closes [#23](https://github.com/cloetzi/lazy-runner/issues/23)
* **mcp:** tell the coach agent how a status, a focus and a reason read on the Coach page ([#30](https://github.com/cloetzi/lazy-runner/issues/30)) ([1dbd36f](https://github.com/cloetzi/lazy-runner/commit/1dbd36f0faab2fa4fe63c21ae421ca010d73624b)), closes [#24](https://github.com/cloetzi/lazy-runner/issues/24)
* **player:** stretches count up, both sides on one screen ([#26](https://github.com/cloetzi/lazy-runner/issues/26)) ([a34ea65](https://github.com/cloetzi/lazy-runner/commit/a34ea656c0b537b0d90441d123237f6c84045341))

## [0.8.0](https://github.com/cloetzi/lazy-runner/compare/v0.7.0...v0.8.0) (2026-11-16)


### ⚠ BREAKING CHANGES

* POST /api/sessions/:id/complete no longer answers `suggestions`, and a `today` that isn't a date is refused on every route.

### Bug Fixes

* **api:** refuse a wrongly typed token scope and an agent's reply with the right error ([#18](https://github.com/cloetzi/lazy-runner/issues/18)) ([6e9b373](https://github.com/cloetzi/lazy-runner/commit/6e9b37368fb56a1276c78b39b82c3260c77e6165)), closes [#3](https://github.com/cloetzi/lazy-runner/issues/3)
* **deps:** lock file maintenance ([#19](https://github.com/cloetzi/lazy-runner/issues/19)) ([d8ebbf0](https://github.com/cloetzi/lazy-runner/commit/d8ebbf0186a40e7065dd949fd327881b04e774de))
* **deps:** update gems ([#10](https://github.com/cloetzi/lazy-runner/issues/10)) ([755de8b](https://github.com/cloetzi/lazy-runner/commit/755de8bec9cfb3218c7ceef0daf33c498578f80f))
* **outbox:** park a change only for the app's own bug answer ([#16](https://github.com/cloetzi/lazy-runner/issues/16)) ([d810613](https://github.com/cloetzi/lazy-runner/commit/d810613644ecbbfd56555bdc631ac8255bb8f19c)), closes [#2](https://github.com/cloetzi/lazy-runner/issues/2)
* **pwa:** escape by default with html templates ([#22](https://github.com/cloetzi/lazy-runner/issues/22)) ([1c710bf](https://github.com/cloetzi/lazy-runner/commit/1c710bfb9176c997a45cf54b36260761007c8aed)), closes [#7](https://github.com/cloetzi/lazy-runner/issues/7)


### Performance Improvements

* **workouts:** read the workout list in a fixed number of queries, and audit the gems in CI ([#20](https://github.com/cloetzi/lazy-runner/issues/20)) ([1753e1d](https://github.com/cloetzi/lazy-runner/commit/1753e1de21e01848d0c6a3ed596bdfa3f81a247e)), closes [#6](https://github.com/cloetzi/lazy-runner/issues/6) [#9](https://github.com/cloetzi/lazy-runner/issues/9)


### Code Refactoring

* Current.today, one Refusal class, session rules on the models, coverage ([#21](https://github.com/cloetzi/lazy-runner/issues/21)) ([95d9374](https://github.com/cloetzi/lazy-runner/commit/95d93746e023693531927d9ecab491afcf56024d)), closes [#8](https://github.com/cloetzi/lazy-runner/issues/8)

## [0.7.0](https://github.com/cloetzi/lazy-runner/compare/v0.6.0...v0.7.0) (2026-11-16)


### ⚠ BREAKING CHANGES

* **security:** existing API tokens no longer work on /api, only on /mcp; make a new token with REST access for a script.

### Features

* **offline:** park a change the server keeps failing on, back up before migrations ([f199f14](https://github.com/cloetzi/lazy-runner/commit/f199f144844f3fb269ac0f2cae2595ee23c9cc3b))


### Bug Fixes

* follow-ups to outbox parking and agent rules ([9243a6f](https://github.com/cloetzi/lazy-runner/commit/9243a6fefff281b5e7b5d4e39666d26a166d2a48))
* **security:** MCP-only API tokens, agent rules in the models, typed params ([9ffc06d](https://github.com/cloetzi/lazy-runner/commit/9ffc06d5e2a6d8e6aa81e1aef8c634ea02493842))

## Changelog

Releases from the first public one on. Versions 0.1.0 to 0.6.0 were made
before the repository was published.
