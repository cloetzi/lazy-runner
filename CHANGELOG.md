# Changelog

## [0.6.0](https://github.com/cloetzi/lazy-runner/compare/v0.5.0...v0.6.0) (2026-11-15)


### ⚠ BREAKING CHANGES

* the weight_suggestions table is dropped, `suggestion` fields leave the API and MCP answers, `pending_suggestions` leaves training_summary, and /complete's `suggestions` is always empty.
* **security:** rake users:reset_password no longer takes PASSWORD= or asks for one; it prints a temporary password to change at the next sign-in.
* **library:** exercises in the API no longer carry `videos`.

### Features

* **calendar:** a month you can read on an iPad in landscape ([#317](https://github.com/cloetzi/lazy-runner/issues/317)) ([5a193f1](https://github.com/cloetzi/lazy-runner/commit/5a193f17b4420127a97a579e6af00a4575b5d91e))
* **calendar:** record every change to the plan, with undo ([#295](https://github.com/cloetzi/lazy-runner/issues/295)) ([7c0e622](https://github.com/cloetzi/lazy-runner/commit/7c0e6220df7209a100c58d3bf9431b453d5f5992)), closes [#258](https://github.com/cloetzi/lazy-runner/issues/258)
* **calendar:** show an agent's changes to the plan, with undo ([#303](https://github.com/cloetzi/lazy-runner/issues/303)) ([4965c1f](https://github.com/cloetzi/lazy-runner/commit/4965c1fa0dec5be76470f0dacc0214c82a8d56d1))
* **calendar:** show who planned it, with one name for the agent ([#280](https://github.com/cloetzi/lazy-runner/issues/280)) ([2938072](https://github.com/cloetzi/lazy-runner/commit/293807245a689cf28f1fecfc33f63dc7e2f8aa1a))
* **calendar:** the month on an iPad in portrait, and a grid that works from a keyboard ([#318](https://github.com/cloetzi/lazy-runner/issues/318)) ([bdb77d3](https://github.com/cloetzi/lazy-runner/commit/bdb77d32a1ab61b2b2e8a0330e573f4579c80773))
* **calendar:** the week header and Today carry the coach ([#288](https://github.com/cloetzi/lazy-runner/issues/288)) ([77e2656](https://github.com/cloetzi/lazy-runner/commit/77e26562af1fe5c8b54cf7ff0ebf31a8d0f607ec))
* **calendar:** the week opens on today, with one vocabulary for sessions and routine days ([#285](https://github.com/cloetzi/lazy-runner/issues/285)) ([bf3540a](https://github.com/cloetzi/lazy-runner/commit/bf3540a40583339fe45802218c6b5b2f92fb9146))
* **coach:** "Since you last looked", with a dot on the Coach tab ([#306](https://github.com/cloetzi/lazy-runner/issues/306)) ([75fcba2](https://github.com/cloetzi/lazy-runner/commit/75fcba27fe879b471e069a20ef0ab7afac573537))
* **coach:** notes where they apply, and a journal you can read ([#294](https://github.com/cloetzi/lazy-runner/issues/294)) ([ceeddb0](https://github.com/cloetzi/lazy-runner/commit/ceeddb0b696f5fc171371fb67f386302015a8af5)), closes [#262](https://github.com/cloetzi/lazy-runner/issues/262)
* **coach:** record an agent's workout edits and weights, with Change it back ([#321](https://github.com/cloetzi/lazy-runner/issues/321)) ([39a28dc](https://github.com/cloetzi/lazy-runner/commit/39a28dcee33b4c19dbb8cf901ca05f683b614a9a)), closes [#290](https://github.com/cloetzi/lazy-runner/issues/290)
* **coach:** reply to a coach's note, and the agent reads the reply with it ([#316](https://github.com/cloetzi/lazy-runner/issues/316)) ([35d5e92](https://github.com/cloetzi/lazy-runner/commit/35d5e924dc18ddd37550560a121463333a06a043))
* **coach:** the current reading first, this week with the runs, goals that say what Accept does ([#314](https://github.com/cloetzi/lazy-runner/issues/314)) ([734e00d](https://github.com/cloetzi/lazy-runner/commit/734e00dc5b257e13ad0c45efd58ec6de8b46cbd8))
* **design:** one field, one segmented control, two ways to show "selected" ([#308](https://github.com/cloetzi/lazy-runner/issues/308)) ([3d36599](https://github.com/cloetzi/lazy-runner/commit/3d36599abaac1c10c00ba89df5343ba6e05e79f7))
* **design:** sizes, colour roles and button kinds in the shared stylesheet ([#307](https://github.com/cloetzi/lazy-runner/issues/307)) ([233ee69](https://github.com/cloetzi/lazy-runner/commit/233ee696b6b729d86f0521e8abe1a3996c607015))
* **equipment:** weights entered as chips, one at a time ([#299](https://github.com/cloetzi/lazy-runner/issues/299)) ([62e4d9e](https://github.com/cloetzi/lazy-runner/commit/62e4d9ed70793bc3072859f82980290570526c68))
* **examples:** add a no-gear example program and three bodyweight exercises ([#293](https://github.com/cloetzi/lazy-runner/issues/293)) ([353395d](https://github.com/cloetzi/lazy-runner/commit/353395d254453876617bf8551caf181982c83601))
* **gear:** owned and missing gear everywhere, example programs under Workouts ([#305](https://github.com/cloetzi/lazy-runner/issues/305)) ([202a1e9](https://github.com/cloetzi/lazy-runner/commit/202a1e96dbdacc63eeef10d424a03fdf594fb0d1))
* **history:** finish and history report the workout, not the skipped stretches ([#301](https://github.com/cloetzi/lazy-runner/issues/301)) ([ee6846c](https://github.com/cloetzi/lazy-runner/commit/ee6846cfef737f8996b2fa85518fbc522599577b)), closes [#265](https://github.com/cloetzi/lazy-runner/issues/265)
* **mcp:** the agent reads the week the user sees ([#279](https://github.com/cloetzi/lazy-runner/issues/279)) ([0a8a416](https://github.com/cloetzi/lazy-runner/commit/0a8a4169ae95f21c329007444762568c208fbb10)), closes [#249](https://github.com/cloetzi/lazy-runner/issues/249)
* **nav:** an icon rail on iPad portrait, the signed-in user, and Back that returns where you came from ([#311](https://github.com/cloetzi/lazy-runner/issues/311)) ([6c8e9a4](https://github.com/cloetzi/lazy-runner/commit/6c8e9a4be77af586c0ee4c9d8fe440f536020115))
* **offline:** the whole app opens offline, and installs without a white flash ([#287](https://github.com/cloetzi/lazy-runner/issues/287)) ([75b4331](https://github.com/cloetzi/lazy-runner/commit/75b4331d1945517f93a1b607569319995000c951)), closes [#267](https://github.com/cloetzi/lazy-runner/issues/267)
* **player:** beeps that mix with music, come back after interruptions, and a Test sound ([#302](https://github.com/cloetzi/lazy-runner/issues/302)) ([52a4842](https://github.com/cloetzi/lazy-runner/commit/52a484214beff674832437a23add832caee9eae0))
* **player:** speak to a screen reader and redraw only what changed ([#286](https://github.com/cloetzi/lazy-runner/issues/286)) ([4f1da06](https://github.com/cloetzi/lazy-runner/commit/4f1da06ce4ce7299f49816740a21698ccddf0e9c)), closes [#245](https://github.com/cloetzi/lazy-runner/issues/245)
* **player:** Start on screen and an honest gear list on Get ready ([#291](https://github.com/cloetzi/lazy-runner/issues/291)) ([142264a](https://github.com/cloetzi/lazy-runner/commit/142264a9d2a6a1902d712beae75c3c5f9fd4597c)), closes [#242](https://github.com/cloetzi/lazy-runner/issues/242)
* **player:** the count is the screen, inside a ring that drains ([#309](https://github.com/cloetzi/lazy-runner/issues/309)) ([9ce44cb](https://github.com/cloetzi/lazy-runner/commit/9ce44cb46d62c8e57495a3f4415100f6004e9f5e)), closes [#256](https://github.com/cloetzi/lazy-runner/issues/256)
* **player:** the rest prepares the next set ([#310](https://github.com/cloetzi/lazy-runner/issues/310)) ([d507dbd](https://github.com/cloetzi/lazy-runner/commit/d507dbd09d62040bff37da0e01e2a98f6d038212))
* remove the app's weight suggestions ([#297](https://github.com/cloetzi/lazy-runner/issues/297)) ([55ffd5c](https://github.com/cloetzi/lazy-runner/commit/55ffd5ccbc1cd300af8e34a5732f1558e28f5d22)), closes [#264](https://github.com/cloetzi/lazy-runner/issues/264)
* **security:** finish the hardening notes from the audit ([#282](https://github.com/cloetzi/lazy-runner/issues/282)) ([bd9553b](https://github.com/cloetzi/lazy-runner/commit/bd9553bc006730edc6d11b38d5c267d6663e1bd9)), closes [#210](https://github.com/cloetzi/lazy-runner/issues/210)
* **settings:** five sections, each with its own address ([#313](https://github.com/cloetzi/lazy-runner/issues/313)) ([5d3bd4b](https://github.com/cloetzi/lazy-runner/commit/5d3bd4bb6e6b304e908ca473fa0feb7447a595f7))
* **signin:** single sign-on first, checked invite links, labelled invites ([#300](https://github.com/cloetzi/lazy-runner/issues/300)) ([a97d42b](https://github.com/cloetzi/lazy-runner/commit/a97d42b8ca8dbff96a4a0dbed2f9ebc3acf8d424))
* **suggestions:** allow one missed rep before suggesting less weight ([#281](https://github.com/cloetzi/lazy-runner/issues/281)) ([9ae8fa9](https://github.com/cloetzi/lazy-runner/commit/9ae8fa96a0cad63014209216fbcd3adbb9dd6d2e)), closes [#250](https://github.com/cloetzi/lazy-runner/issues/250)
* **today:** a first session for someone who has never trained, and empty pages that lead somewhere ([#292](https://github.com/cloetzi/lazy-runner/issues/292)) ([3539040](https://github.com/cloetzi/lazy-runner/commit/353904083e5c709511fd9aea2d5ade868274e410))
* **welcome:** ask the training days, and keep what is left of set-up on Today ([#296](https://github.com/cloetzi/lazy-runner/issues/296)) ([a887d2c](https://github.com/cloetzi/lazy-runner/commit/a887d2c47f772740d0bb804566bbc2bc74af9c0a))
* **workouts:** Edit at the top of a workout, and an editor you can't leave by accident ([#304](https://github.com/cloetzi/lazy-runner/issues/304)) ([266407e](https://github.com/cloetzi/lazy-runner/commit/266407efdd59e5e83cf07662a4c1f6304ad8d4ef)), closes [#268](https://github.com/cloetzi/lazy-runner/issues/268)


### Bug Fixes

* **a11y:** names, headings, targets, contrast and an axe run in the smoke test ([#284](https://github.com/cloetzi/lazy-runner/issues/284)) ([05fc068](https://github.com/cloetzi/lazy-runner/commit/05fc068c8234474cbbd2b63e2f20c05473258b83))
* **library:** remove the demo video links from exercises ([#278](https://github.com/cloetzi/lazy-runner/issues/278)) ([c600b5e](https://github.com/cloetzi/lazy-runner/commit/c600b5e0abfee5c1ea06dc1ebdb0ef1c428ba77a)), closes [#276](https://github.com/cloetzi/lazy-runner/issues/276)
* **player:** taps that register once in a session ([#283](https://github.com/cloetzi/lazy-runner/issues/283)) ([00350e8](https://github.com/cloetzi/lazy-runner/commit/00350e8c26d8a229050d129c30fe175d8eb98a1d)), closes [#241](https://github.com/cloetzi/lazy-runner/issues/241)
* small bugs seen while making the November mock-ups ([#315](https://github.com/cloetzi/lazy-runner/issues/315)) ([463d396](https://github.com/cloetzi/lazy-runner/commit/463d39699f7de410bc049f84e64dc0f1fc5aab6a))
* **ui:** first-screen fixes and wording for a new account ([#289](https://github.com/cloetzi/lazy-runner/issues/289)) ([74dcb4c](https://github.com/cloetzi/lazy-runner/commit/74dcb4c8c973dfdc8f94601b41c9b5d5f84b5cfd))
* **ui:** readable figure props, a paused count at full contrast, one page edge ([#277](https://github.com/cloetzi/lazy-runner/issues/277)) ([9a6d3cf](https://github.com/cloetzi/lazy-runner/commit/9a6d3cf989a0d4155b66843568a0aaf7405f52de))
* **weights:** keep a step's weights in the unit of the gear it is done with ([#319](https://github.com/cloetzi/lazy-runner/issues/319)) ([6f3a5de](https://github.com/cloetzi/lazy-runner/commit/6f3a5deb4dd2caa7e9528fd439acc5a9cc27f026))
* **weights:** step back to no weight, keep a step's weight in its gear's unit ([#238](https://github.com/cloetzi/lazy-runner/issues/238)) ([3152b7e](https://github.com/cloetzi/lazy-runner/commit/3152b7e1454e165bba763983d49c407991ce9e7c)), closes [#230](https://github.com/cloetzi/lazy-runner/issues/230)

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
