# Changelog

## [0.5.0](https://github.com/cloetzi/lazy-runner/compare/v0.4.0...v0.5.0) (2026-11-10)


### ⚠ BREAKING CHANGES

* **library:** exercises in the API carry `videos` in place of the unused `video_url`.

### Features

* **equipment:** a generic weight for exercises where any dumbbell or kettlebell will do ([#229](https://github.com/cloetzi/lazy-runner/issues/229)) ([4ab72dc](https://github.com/cloetzi/lazy-runner/commit/4ab72dc82faa2f972e1bd5098218dc6fe4611032))
* **exercises:** say whether reps count per side or in total ([#227](https://github.com/cloetzi/lazy-runner/issues/227)) ([2457ff3](https://github.com/cloetzi/lazy-runner/commit/2457ff358d9a6ee2cb1034914d6f8716fb407905))
* **library:** demo video links on exercises ([#236](https://github.com/cloetzi/lazy-runner/issues/236)) ([d74a6f8](https://github.com/cloetzi/lazy-runner/commit/d74a6f8fc00ff06d5e03d01292eca91f398450ed)), closes [#235](https://github.com/cloetzi/lazy-runner/issues/235)
* **mcp:** let the coach agent list, change and delete its own notes ([#220](https://github.com/cloetzi/lazy-runner/issues/220)) ([26e1446](https://github.com/cloetzi/lazy-runner/commit/26e1446b44fc3b7eb4373a912c40f13974142d94)), closes [#219](https://github.com/cloetzi/lazy-runner/issues/219)
* **player:** a visible Pause button and a longer lead-in when the gear changes ([#232](https://github.com/cloetzi/lazy-runner/issues/232)) ([a2c846d](https://github.com/cloetzi/lazy-runner/commit/a2c846d2af56819ffcbbff78227d986e6c8748d4))
* **routines:** plan runs and other sports as tentative routines on the calendar ([#218](https://github.com/cloetzi/lazy-runner/issues/218)) ([6af7c55](https://github.com/cloetzi/lazy-runner/commit/6af7c553fd235c947a10152e1f87a30195f232a6))


### Bug Fixes

* **player:** keep the exercise figure whole and clear of the text ([#234](https://github.com/cloetzi/lazy-runner/issues/234)) ([21b6e9f](https://github.com/cloetzi/lazy-runner/commit/21b6e9f3591dfb5ae8a4d4abdd3f10b8c0d5b489))
* **player:** show all gear equally on Get ready and set a weight for any weighted step ([#228](https://github.com/cloetzi/lazy-runner/issues/228)) ([6b18560](https://github.com/cloetzi/lazy-runner/commit/6b1856009b390dbb9e4c9d09feb648f400871f54))
* **pwa:** tell a lost sign-in from offline and always offer a way out ([#223](https://github.com/cloetzi/lazy-runner/issues/223)) ([9d19a7f](https://github.com/cloetzi/lazy-runner/commit/9d19a7fad3739f8baff3ea126570286a115bd5df))

## [0.4.0](https://github.com/cloetzi/lazy-runner/compare/v0.3.0...v0.4.0) (2026-11-09)


### Features

* **mcp:** fix what tripped the coach agent building workouts ([#217](https://github.com/cloetzi/lazy-runner/issues/217)) ([0d447f3](https://github.com/cloetzi/lazy-runner/commit/0d447f39ef4e5f163e8983905ff8ef817955f551))
* **mcp:** log_activities and list_activities for the trainer agent ([#214](https://github.com/cloetzi/lazy-runner/issues/214)) ([4e3606c](https://github.com/cloetzi/lazy-runner/commit/4e3606c96e19571bf4b379b7fa877de119d43c90)), closes [#180](https://github.com/cloetzi/lazy-runner/issues/180)

## [0.3.0](https://github.com/cloetzi/lazy-runner/compare/v0.2.0...v0.3.0) (2026-11-09)


### ⚠ BREAKING CHANGES

* **security:** with OIDC_ISSUER set, OIDC_REDIRECT_URI is required and must end in /api/auth/oidc/callback.

### Features

* **auth:** sign in with an OpenID Connect provider ([#203](https://github.com/cloetzi/lazy-runner/issues/203)) ([46188a3](https://github.com/cloetzi/lazy-runner/commit/46188a3bc9f3611a2b4ec6cf39db33311a79a5bf))
* **settings:** explain connecting an MCP client on the API tokens card ([#213](https://github.com/cloetzi/lazy-runner/issues/213)) ([35ae506](https://github.com/cloetzi/lazy-runner/commit/35ae50656314e24a5b3a43f6a0c27358aaad8347))
* show the running app version on Settings and in /api/version ([#200](https://github.com/cloetzi/lazy-runner/issues/200)) ([fb9ff5a](https://github.com/cloetzi/lazy-runner/commit/fb9ff5a2a76742f55985f5214ed64de5f045668b))


### Bug Fixes

* **security:** fix the findings of the 2026-11-07 security audit ([#211](https://github.com/cloetzi/lazy-runner/issues/211)) ([f1940d4](https://github.com/cloetzi/lazy-runner/commit/f1940d4a7e560da76b02011abeca2d713ed8bb11))

## [0.2.0](https://github.com/cloetzi/lazy-runner/compare/v0.1.0...v0.2.0) (2026-11-02)


### ⚠ BREAKING CHANGES

* **auth:** POST /api/auth/setup is now POST /api/auth/create-account, which takes setup_code or invite.
* **examples:** slug on programs and workouts is now example_slug, source seed is gone, a new account starts with no equipment and no programs, and GET /api/today with nothing to train is a 404 with the code no_workouts.
* **data:** the data of the one-user install is dropped on upgrade, after a copy to storage/<name>.before-per-user.sqlite3. PATCH
* **auth:** the API and /mcp need a session. /mcp is closed until API tokens ([#37](https://github.com/cloetzi/lazy-runner/issues/37)) land. Plain-http installs need SECURE_COOKIES=false.
* **api:** a workout step's `equipment` in GET /api/workouts/:id is the step's own gear or null; read `equipment_needed` for what it is done with.

### Features

* **activities:** show runs and other sports on the calendar ([#190](https://github.com/cloetzi/lazy-runner/issues/190)) ([ed5ec1e](https://github.com/cloetzi/lazy-runner/commit/ed5ec1ed6c1662e421eb7c21d96e49723d5268f1))
* **api:** build workouts and replace their blocks and steps ([#157](https://github.com/cloetzi/lazy-runner/issues/157)) ([3920d88](https://github.com/cloetzi/lazy-runner/commit/3920d88bb7b5dc184841101e79e71095ce3eaa06)), closes [#142](https://github.com/cloetzi/lazy-runner/issues/142)
* **auth:** onboarding and invites ([#193](https://github.com/cloetzi/lazy-runner/issues/193)) ([a964c45](https://github.com/cloetzi/lazy-runner/commit/a964c45f2668e027e85afc6e0a2c2528293105ff)), closes [#184](https://github.com/cloetzi/lazy-runner/issues/184)
* **auth:** personal API tokens for MCP and scripts ([#187](https://github.com/cloetzi/lazy-runner/issues/187)) ([f72ed3f](https://github.com/cloetzi/lazy-runner/commit/f72ed3fdf8658fd62becf62e54c7d2d2a9e0a5a3)), closes [#37](https://github.com/cloetzi/lazy-runner/issues/37)
* **auth:** sign in with a username and password ([#186](https://github.com/cloetzi/lazy-runner/issues/186)) ([d399e21](https://github.com/cloetzi/lazy-runner/commit/d399e213d47300532b0b2b7ba386f17b763b3893)), closes [#182](https://github.com/cloetzi/lazy-runner/issues/182)
* **builder:** create and edit your own workouts in the app ([#162](https://github.com/cloetzi/lazy-runner/issues/162)) ([33398c0](https://github.com/cloetzi/lazy-runner/commit/33398c0cc01503da7f310c26c29684fade56ee29)), closes [#144](https://github.com/cloetzi/lazy-runner/issues/144)
* **calendar:** plan, move and skip workouts by day ([#163](https://github.com/cloetzi/lazy-runner/issues/163)) ([758a80e](https://github.com/cloetzi/lazy-runner/commit/758a80e64d0bc1fe09e0c3ceba619d306ca128b3))
* **coach:** Coach tab with goals, status, focus, concerns and notes ([#194](https://github.com/cloetzi/lazy-runner/issues/194)) ([ebc1455](https://github.com/cloetzi/lazy-runner/commit/ebc14554967f0b5fd5fd2a6fc1a98b785f4dc4b5))
* **data:** keep each user's data to themselves ([#188](https://github.com/cloetzi/lazy-runner/issues/188)) ([c0c3621](https://github.com/cloetzi/lazy-runner/commit/c0c3621306a98e6e7c31b643caf5efe913ede8f5))
* **examples:** programs are examples a user imports ([#191](https://github.com/cloetzi/lazy-runner/issues/191)) ([130adac](https://github.com/cloetzi/lazy-runner/commit/130adace035d6c07918a5824a9e3383670279174)), closes [#183](https://github.com/cloetzi/lazy-runner/issues/183)
* **mcp:** let the trainer build workouts and plan them on the calendar ([#164](https://github.com/cloetzi/lazy-runner/issues/164)) ([90457d4](https://github.com/cloetzi/lazy-runner/commit/90457d41241378b95d33c231b9d61a2279053497)), closes [#145](https://github.com/cloetzi/lazy-runner/issues/145)
* **mcp:** serve read tools and a trainer brief at /mcp ([#158](https://github.com/cloetzi/lazy-runner/issues/158)) ([edebd02](https://github.com/cloetzi/lazy-runner/commit/edebd02296861e7239407e4a807abaf27f8a513d)), closes [#143](https://github.com/cloetzi/lazy-runner/issues/143)
* plan, move and order sessions on a calendar; Today lists the day ([#151](https://github.com/cloetzi/lazy-runner/issues/151)) ([480d46f](https://github.com/cloetzi/lazy-runner/commit/480d46ff51e84d07a6b03769435854ea5c7cb1b2)), closes [#147](https://github.com/cloetzi/lazy-runner/issues/147)


### Bug Fixes

* **api:** keep workout edits safe from stale runs, archived frames and old gear ([#169](https://github.com/cloetzi/lazy-runner/issues/169)) ([c29a182](https://github.com/cloetzi/lazy-runner/commit/c29a182434522d8dfaf67c7cc287ac22dc52a215)), closes [#167](https://github.com/cloetzi/lazy-runner/issues/167)
* onboarding, gear units, example preview and Exercises filters from testing ([#196](https://github.com/cloetzi/lazy-runner/issues/196)) ([51e17da](https://github.com/cloetzi/lazy-runner/commit/51e17daf7736ceb2045ea5b023261cada8bcdbe5))
* **sessions:** keep offline sets, order a day by finish time, plan on the device's today ([#170](https://github.com/cloetzi/lazy-runner/issues/170)) ([65caed1](https://github.com/cloetzi/lazy-runner/commit/65caed14c1575d1d9c4126f650399551af1a13d4)), closes [#161](https://github.com/cloetzi/lazy-runner/issues/161) [#166](https://github.com/cloetzi/lazy-runner/issues/166) [#159](https://github.com/cloetzi/lazy-runner/issues/159)

## 0.1.0 (2026-10-26)


### Features

* release with release-please and publish the image for each release ([#153](https://github.com/cloetzi/lazy-runner/issues/153)) ([22b6fe1](https://github.com/cloetzi/lazy-runner/commit/22b6fe10fd982fcaa36f612cc59cbdbf358eb434))
