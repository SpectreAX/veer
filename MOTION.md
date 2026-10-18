# Motion Design System

## 1. Purpose

This document is the canonical motion specification for Veer. It defines how the
Android application moves; it does not authorize motion by default.

`AGENTS.md` defines how Veer looks and behaves. `MOTION.md` defines how that
interface moves. Neither document may contradict the other. There is currently
no separate `DESIGN.md`; if one is added, all three documents must remain
consistent.

Before changing UI motion, contributors must read:

1. `AGENTS.md`
2. this document
3. the relevant runtime and screen architecture

Veer is a native Kotlin and Jetpack Compose proxy/VPN application. Its motion
must communicate real connection state, navigation hierarchy, direct feedback,
and spatial continuity. It must not become a decorative layer over the UI.

### Current baseline

- App-owned Compose animations are not yet implemented. Existing visible motion
  comes from Material 3 controls, ripples, and progress indicators.
- `VeerMotion` already defines `quick = 150`, `standard = 250`, and
  `emphasized = 300` milliseconds in `app/src/main/java/com/yamax/veer/ui/theme/VeerTokens.kt`.
- The top level is five Android activities connected by a shared Material 3
  bottom navigation bar. Secondary destinations do not show that bar.
- Runtime state belongs to `:veercore`. The UI process observes an AIDL-backed
  state mirror and must never invent lifecycle state for presentation.

## 2. Motion Philosophy

Veer motion is **state made legible**.

Every animation must answer at least one of these questions:

- What changed?
- What caused the change?
- Where did the content come from or go?
- Is the action acknowledged, pending, complete, or failed?
- Which element now has priority?

If motion cannot improve comprehension, feedback, hierarchy, continuity, or
trust, do not add it. “It looks nicer” is not sufficient justification.

Use the lightest native mechanism that expresses the interaction correctly.
Motion must be interruptible, retargetable, and subordinate to real application
state. The interface never waits for an animation before reporting a connection,
error, selection, or operation result.

## 3. Motion Personality

Veer should feel:

- precise and responsive;
- calm rather than inert;
- technical without feeling mechanical;
- lightweight and power-conscious;
- trustworthy and state-faithful;
- native to Android and spatially coherent.

The reference direction is Android system UI × standard Material 3 motion × a
modern developer tool. Do not import playful, elastic, cinematic, or web-style
motion into the product.

## 4. Core Principles

### 4.1 State truth comes first

The primary lifecycle is:

```text
Stopped → Starting → Running → Stopping → Stopped
             │          │
             └──────────┴──────────────→ Error
```

Quick reconnect follows the real service sequence:

```text
Running → Stopping → Starting → Running
```

It intentionally emits no intermediate `Stopped` frame. Motion must preserve
that continuity rather than assuming every sequence passes through `Stopped`.

`Error` can mean the native runtime is still being cleaned up. Do not animate it
as a safe stopped state. Preserve the error message and the “clean up and stop”
action until the runtime reports a new state.

### 4.2 Motion observes state; it does not control state

- Business logic publishes state immediately.
- Animation targets derive from the latest state.
- A new state interrupts or retargets in-flight motion.
- Never hold, replay, or fabricate UI state so an animation can finish.
- Never chain runtime actions to animation completion callbacks.

### 4.3 Hierarchy determines intensity

The connection lifecycle may receive the most coordinated motion. Component
feedback is shorter and quieter. Routine telemetry and list refreshes normally
receive no entrance motion.

### 4.4 Consistency beats novelty

Use the tokens and patterns in this document. Do not scatter custom durations,
easings, spring parameters, offsets, or per-screen animation languages.

### 4.5 Accessibility and performance are design constraints

Reduced motion, animation scale zero, screen readers, small screens, dark mode,
and frequent network updates are normal operating conditions, not edge cases.

## 5. Motion Hierarchy

### Level 1 — Micro-interactions

Purpose: acknowledge a direct touch or a small local state change.

Examples: Material ripple, selection color, enabled/disabled state, status icon
or label replacement. Use Material 3 defaults or the `Quick` token. Do not add a
global button scale effect.

### Level 2 — Component transitions

Purpose: explain a component changing shape, content, or visibility.

Examples: an inline status panel appearing, startup-stage text changing, or a
card gaining its selected state. Use `Quick` to `Standard` timing.

### Level 3 — Navigation / major state changes

Purpose: preserve hierarchy across a screen-level or major branch change.

Use native Android/Material navigation behavior. Custom transitions require a
stable spatial relationship and must fit the existing multi-activity
architecture. They are not automatically warranted for bottom navigation.

### Level 4 — Signature motion

Purpose: reinforce product identity at one exceptional, high-value moment.

Veer has one candidate: **connection-state continuity** across `Stopped`,
`Starting`, `Running`, `Stopping`, and `Error`. It coordinates existing status,
action, and progress elements; it does not add a decorative logo animation,
glow, halo, or ambient pulse.

No second signature pattern is approved. A node-selection continuity pattern may
be reconsidered only after the connection pattern has been implemented and
evaluated.

## 6. Duration Tokens

Canonical values:

| Token | Value | Use |
|---|---:|---|
| `Instant` | `0ms` | A deliberate snap when animation would be misleading or reduced motion requires it |
| `Quick` | `150ms` | Touch-adjacent feedback, exits, icon/label/color changes |
| `Standard` | `250ms` | Component entrances, content changes, coordinated local state |
| `Emphasized` | `300ms` | Important connection or container transitions |
| `Slow` | `400ms` | Rare future screen/container continuity; requires written justification |

`Quick`, `Standard`, and `Emphasized` map to the existing `VeerMotion` constants.
If `Instant` or `Slow` becomes necessary, add it centrally rather than declaring
an inline value.

Rules:

- An exit should usually be `Quick`.
- An entrance should usually be `Standard`.
- An important coordinated state change may use `Emphasized`.
- Ordinary interaction animations must not reach `500ms`.
- Do not stack independent delays. Veer content should remain usable immediately.
- A sequence may overlap related elements by 30–50ms only when that overlap makes
  causality clearer. Decorative stagger is not allowed.

## 7. Easing Tokens

These are the semantic easing definitions for future centralized implementation:

| Token | Compose target | Use |
|---|---|---|
| `Standard` | `CubicBezierEasing(0.2f, 0f, 0f, 1f)` | On-screen state/property changes |
| `Enter` | `CubicBezierEasing(0.05f, 0.7f, 0.1f, 1f)` | Content entering and settling |
| `Exit` | `CubicBezierEasing(0.3f, 0f, 0.8f, 0.15f)` | Content leaving promptly |
| `Linear` | `LinearEasing` | Determinate progress or physically uniform motion only |

Do not paste these curves into feature code. When the first motion is
implemented, expose only the definitions actually needed through the theme
motion tokens.

## 8. Spring Tokens

Use a spring only when interruption, target changes, or direct manipulation makes
a duration-based tween less correct. Veer does not use bouncy springs.

| Token | Damping ratio | Stiffness | Use |
|---|---:|---:|---|
| `Responsive` | `1.0` / `DampingRatioNoBouncy` | `1500` / `StiffnessMedium` | Small, touch-adjacent retargeting |
| `Smooth` | `1.0` / `DampingRatioNoBouncy` | `400` / `StiffnessMediumLow` | Larger spatial continuity with no overshoot |

Do not add an “expressive” or bouncy preset. If a spring visually overshoots, it
does not fit Veer.

### Spatial limits

| Token | Distance | Use |
|---|---:|---|
| `None` | `0dp` | Default for state and text changes |
| `Micro` | `2dp` | Rare touch-adjacent or indicator adjustment |
| `Short` | `8dp` | Inline panel entrance/exit |
| `Container` | `16dp` maximum | Rare major container continuity |

Larger travel requires a real source-to-destination relationship. It is not a
generic entrance effect.

## 9. Entrance Patterns

- Existing screen content is present immediately; do not animate an entire screen
  simply because it was composed.
- An occasional inline panel may combine opacity with at most `Short` vertical
  travel over `Standard` timing and `Enter` easing.
- A structural branch may crossfade or use a restrained `AnimatedContent`
  transition when the incoming layout has a meaningfully different shape.
- Lazy list rows do not cascade or replay entrances after refresh, filtering,
  probing, or process recreation.
- Do not use blur, rotation, scale from zero, or overshoot for entrances.

## 10. Exit Patterns

- Exits use `Quick` timing and `Exit` easing unless the component is participating
  in direct manipulation.
- Prefer opacity and, when spatial origin matters, no more than `Short` travel.
- Remove invisible content from composition with `AnimatedVisibility` when its
  semantics and layout should no longer exist.
- Never keep a dismissed element interactive while it fades out.
- A state update must not wait for its outgoing visual to complete.

## 11. Content Transitions

- Key transitions by **visual state shape**, not by every new data object.
- Use text/icon/color replacement for equal-shape state changes.
- Use `AnimatedContent` when branches have materially different structure.
- Use `Crossfade` only when spatial continuity is irrelevant and both branches
  are small.
- Repeated network samples, logs, latency numbers, chart points, and probe results
  should update directly. Do not make functional data feel unstable.
- Error content must remain readable and actionable; never flash through it.

## 12. Navigation Motion

Veer currently uses five top-level activities with a shared Material 3
`NavigationBar`. That architecture is authoritative.

- Let the Material navigation item indicator and ripple provide local selection
  feedback.
- Preserve Android's platform activity, system back, and predictive-back
  expectations.
- Do not add custom full-screen sliding or page-cover transitions to bottom-tab
  changes.
- Do not emulate a single-composition navigation stack solely to gain animation.
- If navigation is later consolidated, redesign and validate screen transitions
  at that architectural boundary; do not copy old activity assumptions forward.

## 13. Shared Element Motion

No shared-element transition is currently approved. Compose shared-transition
APIs are appropriate only when:

- both endpoints participate in a compatible composition/navigation lifecycle;
- the element has stable identity at both endpoints;
- the transition clarifies where an object moved;
- state restoration, interruption, back navigation, and reduced motion work;
- the benefit justifies the implementation and testing cost.

The current multi-activity top level is not a reason to force shared transitions.
Do not add a runtime dependency for this capability.

## 14. Gesture Motion

- Use native scrolling, overscroll, touch indication, and predictive back.
- Gesture-driven animation must follow the pointer continuously and settle with
  an interruptible `Animatable` or an appropriate anchored gesture API.
- Do not hide destructive or primary VPN actions behind swipe gestures.
- Do not continue a decorative settling animation after the user starts a new
  gesture.
- Veer is a touch application; web-style hover behavior is out of scope.

## 15. Scroll Motion

- No scroll-jacking, parallax, viewport-triggered section entrances, sticky
  decorative transforms, or velocity-reactive backgrounds.
- Do not animate chart or telemetry containers as they scroll into view.
- If a collapsing container is ever added, read rapidly changing scroll state in
  layout/draw or `graphicsLayer` when possible rather than recomposing the full
  subtree every frame.
- Keep scrolling and list manipulation visually stable during data refreshes.

## 16. Loading / Progress Motion

- Prefer Material 3 progress indicators.
- Determinate progress must reflect real work milestones or real measurements.
- Startup progress derives from the published `StartupStage`; it must never use a
  timer to predict VPN startup duration.
- When a stage takes longer, the indicator stays truthfully at that stage.
- Indeterminate progress is allowed when completion cannot be measured, paired
  with clear text describing the operation.
- Do not add continuous pulses, orbiting elements, or multiple simultaneous
  loaders.
- Loading motion stops or disappears as soon as real state changes.

## 17. State Change Motion

### Connection state machine

The status badge, primary action, startup progress, reconnect affordance, and
runtime dashboard should read as parts of one state machine:

- `Stopped`: stable neutral status; start action available when configuration
  prerequisites are met.
- `Starting`: status/action retarget immediately, startup progress appears from
  real `StartupStage`, and duplicate start is disabled.
- `Running`: connected semantics become stable; startup progress leaves; runtime
  data and reconnect affordance become available.
- `Stopping`: status/action retarget immediately; running-only actions disappear
  or disable; no false `Stopped` presentation.
- `Error`: error semantics and cleanup action take priority. Do not imply that the
  tunnel or native runtime has already stopped.

Use coordinated property transitions only where they preserve the identity of an
existing component. Structural changes may use `AnimatedVisibility` or
`AnimatedContent`, keyed to the visual branch. Every animation must tolerate the
next real state arriving before it finishes.

### Other state

- Selection: update color, border, icon, and label together within `Quick` or
  `Standard` timing; do not move the row.
- Validation: show text and semantic color close to the field/action; do not
  shake the UI.
- Success/error banners: an occasional `Short` entrance is allowed, with a
  screen-reader announcement where appropriate.
- Enabled/disabled: visual and semantic state change immediately; opacity or
  color may settle over `Quick` timing.

## 18. Image / Media Motion

Veer does not currently have an image-led or media-led interaction that warrants
custom motion. Launcher art, icons, and decorative assets must not animate merely
because animation is technically possible.

Lottie is reserved for a rare, authored illustration that conveys a state better
than native Compose primitives. It is not approved for the connection indicator,
loading, success, or navigation, and installing the `motion-design` Agent Skill
does not install or justify the Lottie runtime.

## 19. Hover / Press / Touch Feedback

- Material 3 ripple and control-state feedback are the default.
- Keep minimum touch targets and accessibility semantics from `AGENTS.md`.
- Do not apply scale, rotation, bounce, glow, or shadow pulses to every button or
  card.
- A pressed-state transform is allowed only for a specialized direct-manipulation
  control with a documented need; ordinary buttons do not qualify.
- Disabled controls do not animate as if an action was accepted.

## 20. Reduced Motion

Veer must respect Android animation and accessibility expectations.

- Use standard Compose animation APIs so platform `MotionDurationScale` behavior
  is honored. Never override the scale to force motion.
- At animation scale `0`, state must settle on the next frame without losing
  information or blocking behavior.
- Custom canvas animation, infinite transitions, or manual frame loops must
  explicitly stop or snap when motion is disabled.
- Reduced motion removes spatial travel, spring settling, repeated rotation,
  pulse, and decorative sequencing.
- Preserve hierarchy and feedback through text, icon, semantic color, selection,
  enabled state, progress value, and an immediate or short opacity change.
- Animation is never the sole indicator of connection, error, selection,
  progress, or action completion.
- Important asynchronous updates must remain available to accessibility services;
  use semantics or live-region behavior where appropriate.

Validate every implemented pattern with system animation scale `0×`, `1×`, and
`10×`. At `10×`, state must remain correct and interaction must not be blocked.

## 21. Performance Rules

- Prefer `graphicsLayer` transforms and alpha when the same visual result would
  otherwise require composition or layout every frame.
- Prefer deferred state reads in layout or draw for frame-rate-driven values.
- Never launch `Animatable.animateTo` directly from composition; use an event or
  an effect keyed to the real target.
- Do not recompose large screen subtrees for every animation frame.
- Avoid animated width, height, padding, margin, placement, blur, shadow, or
  clipping when a transform or direct state update conveys the same information.
- Avoid expensive layout animation in lazy lists. Keep stable keys and do not
  replay row entrances after ordinary refreshes.
- Do not animate frequent network updates, speed samples, logs, latency probes,
  controller polling, or rapidly changing counters by default.
- Keep high-frequency runtime data out of unrelated composables. Motion state
  should be local to the smallest stable owner.
- Key `AnimatedContent` by visual branch so a new data instance does not replay an
  entrance.
- Infinite animations require a functional purpose, a lifecycle stop condition,
  and a reduced-motion alternative. None is currently approved.
- Profile before approving motion that affects lists, charts, startup, or the
  connection dashboard. Target smooth rendering on supported devices, not just
  emulator correctness.

## 22. Responsive / Mobile Motion

- Veer has no desktop hover motion.
- On compact screens, keep travel within the same `Short`/`Container` limits; do
  not increase it because elements are closer together.
- Long translated strings and large font scales must not be clipped during
  `AnimatedContent` or visibility changes.
- Motion must work in light and dark themes without using stronger glow or shadow
  to compensate for contrast.
- Orientation, window-size, and process recreation should restore the latest real
  state, not replay a ceremonial entrance.

## 23. Animation Technology Decision Matrix

Choose the smallest API that correctly models the state:

| Need | Preferred technology | Use when | Do not use when |
|---|---|---|---|
| Standard touch/control feedback | Material 3 built-ins | Ripple, progress, navigation selection, standard control state | Replacing a clear native behavior with custom motion |
| One value follows one state | `animate*AsState` | A local color, alpha, size, offset, or progress target | Multiple properties require a shared transition or imperative control |
| A subtree appears/disappears | `AnimatedVisibility` | The node, layout, and semantics should enter/leave together | Only alpha changes while the node must remain interactive or laid out |
| One visual branch replaces another | `AnimatedContent` | Branches have different shape and a stable `contentKey` | Every new data value would retrigger the transition |
| Simple equal-size visual replacement | `Crossfade` | Spatial direction is irrelevant and content is small | The spatial relationship or layout change needs explanation |
| Several properties follow one state machine | `rememberTransition` (or toolchain-equivalent `updateTransition`) | Color, icon, alpha, and container properties must remain synchronized | Each property is unrelated or only one value changes |
| Gesture or interruptible imperative value | `Animatable` | Direct manipulation, decay, bounds, velocity, or explicit interruption is required | A declarative target-state API is sufficient |
| Shared source/destination identity | Compose shared-transition APIs | Endpoints share a compatible composition/navigation lifecycle and stable ID | Current top-level activity boundaries or uncertain identity |
| Frame-rate transform/alpha | `Modifier.graphicsLayer` | Draw-time translation, scale, rotation, or alpha avoids recomposition/layout | It would hide incorrect layout or accessibility bounds |
| Frame-rate custom drawing | Canvas / `drawBehind` with deferred reads | The visual is genuinely custom and state remains semantic elsewhere | A Material or standard Compose component already expresses it |
| Authored illustration | Lottie runtime, only after approval | A rare product illustration has a reviewed asset and functional purpose | Status, progress, button, list, or navigation motion |

Do not add a runtime animation library merely because an Agent Skill is present.
No third-party motion runtime is currently required.

### Guidance precedence

When installed Skills disagree, follow this order:

1. Official Android/Compose APIs and Veer's real architecture/state invariants.
2. Chris Banes Compose guidance.
3. Aldefy's `compose-expert` guidance.
4. Generic `motion-design` guidance.

Generic concepts such as ambient motion or mandatory layered movement are
optional decision aids, not requirements. Veer's normal pattern has no ambient
layer.

## 24. Anti-patterns

Do not introduce:

- animation on every component, screen entry, or viewport intersection;
- scale-from-zero dialogs, cards, menus, or status elements;
- excessive bounce, overshoot, elastic easing, wobble, glow, or particle effects;
- arbitrary interaction animations of `500ms` or longer;
- repeated lazy-list or screen entrances after routine recomposition or refresh;
- transitions that block touch, back, state reporting, or the next operation;
- UI animation state that contradicts `EngineState`, `StartupStage`, selection,
  profile, or operation state;
- timers that simulate startup progress or success;
- animation-completion callbacks that advance VPN business state;
- continuous connection halos, breathing cards, rotating backgrounds, or ambient
  activity while the VPN is stable;
- animation of every network speed, log, latency, or probe update;
- arbitrary duration, easing, offset, or spring values in feature code;
- multiple competing animation languages on one screen;
- expensive per-frame recomposition or layout for a draw-layer effect;
- hidden or removed accessibility semantics during a visual transition;
- custom activity/navigation architecture solely to enable a transition;
- a major runtime dependency without a concrete interaction, benchmark, reduced
  motion plan, and review justification.

The web-specific rule `transition: all` has no Compose equivalent, but its intent
applies: animate named properties deliberately, never every property by default.

## 25. Motion Opportunities

This audit identifies six candidates. It is a plan, not implementation approval.
Only implement one reviewed opportunity at a time.

### Opportunity 1 — Connection lifecycle continuity

- **Location:** `HomeScreen.RuntimeSection`, `VeerStatusBadge`, the primary
  connection action, startup panel, reconnect action, and runtime dashboard.
- **Trigger:** A real `EngineState` update from the runtime state mirror.
- **Element:** Existing status, action label/icon, progress, reconnect, and
  dashboard regions.
- **Motion:** Coordinate label/icon/color changes over `Quick`; enter major
  state-dependent content over `Standard`; exit it over `Quick`. Retarget
  immediately when a newer state arrives. No card bounce, halo, or fake hold.
- **Purpose:** Make lifecycle, action availability, and continuity comprehensible
  while preserving trust in the runtime.
- **Priority:** **P0**.
- **Proposed implementation:** A transition keyed to the real sealed state for
  coordinated properties, `AnimatedContent` keyed by visual branch, and
  `AnimatedVisibility` for structural regions.
- **Reduced motion:** Snap spatial/structural changes; preserve immediate
  text/icon/color/action state and optional short opacity feedback.

### Opportunity 2 — Real startup milestones

- **Location:** `StartupProgressPanel` on the home screen.
- **Trigger:** A real `StartupStage` milestone while `EngineState.Starting`.
- **Element:** Determinate progress bar, stage count, percentage, and stage label.
- **Motion:** Retarget progress over at most `Standard` timing; replace stage text
  with a `Quick` restrained crossfade. Never interpolate through unpublished
  stages and never delay a newer stage.
- **Purpose:** Clarify that startup is progressing through real work and which
  operation currently owns time.
- **Priority:** **P1**.
- **Proposed implementation:** `animateFloatAsState` for real progress and small
  `AnimatedContent`/`Crossfade` keyed to the stage's visual label.
- **Reduced motion:** Progress and text snap to the latest real milestone.

### Opportunity 3 — Node selection confirmation

- **Location:** Node rows/group cards in `NodesActivity`.
- **Trigger:** A real busy, selected, success, or failure state from node
  selection/probing logic.
- **Element:** Selected container treatment, status badge/icon, and local action
  availability.
- **Motion:** Settle semantic color and indicator replacement together within
  `Quick` or `Standard`; keep row position and list geometry stable.
- **Purpose:** Confirm the selected route and distinguish acknowledged work from a
  completed selection without destabilizing the list.
- **Priority:** **P1**.
- **Proposed implementation:** `animateColorAsState` or a small coordinated state
  transition plus `AnimatedContent` for equal-size status content.
- **Reduced motion:** Immediate semantic color, text, and icon update.

### Opportunity 4 — Profile activation continuity

- **Location:** `ProfileScreen.ProfileCard` and profile switch status panel.
- **Trigger:** Real switch target, in-progress, confirmed active, or failure state.
- **Element:** Active-card treatment, badge/action content, and inline status.
- **Motion:** Transition semantic card/badge properties within `Quick` or
  `Standard`; enter the occasional operation panel over `Standard` and exit over
  `Quick`. Do not imply activation before confirmation.
- **Purpose:** Preserve identity between the chosen profile, the operation in
  progress, and the confirmed active configuration.
- **Priority:** **P1**.
- **Proposed implementation:** Coordinated transition for card properties and
  `AnimatedVisibility` for the inline status. No shared-element transition.
- **Reduced motion:** Immediate card/badge state; status appears without travel.

### Opportunity 5 — Loading/content/empty/error branch continuity

- **Location:** `NodesContent` and other existing state screens when they switch
  between loading, content, empty, and error branches.
- **Trigger:** The real screen-state branch changes.
- **Element:** The state container, not each descendant row.
- **Motion:** A restrained `Quick` fade with at most `Micro`/`Short` entrance
  travel. Key by branch so ordinary data refreshes do not replay it.
- **Purpose:** Explain a structural branch replacement and preserve hierarchy.
- **Priority:** **P1**.
- **Proposed implementation:** `AnimatedContent` with a stable branch
  `contentKey`; use `AnimatedVisibility` only for a true subtree toggle.
- **Reduced motion:** Snap branch; preserve state icon, title, action, and
  semantics.

### Opportunity 6 — Inline asynchronous feedback

- **Location:** Home AI feedback, node message panels, profile import/switch
  feedback, and comparable operation-local messages.
- **Trigger:** A real operation becomes pending, succeeds, or fails.
- **Element:** The local feedback panel closest to the initiating action.
- **Motion:** Enter once with opacity and at most `Short` travel over `Standard`;
  exit over `Quick`. A data update within the same panel does not replay entrance.
- **Purpose:** Connect action to result, improve local feedback, and keep errors
  discoverable.
- **Priority:** **P2**.
- **Proposed implementation:** `AnimatedVisibility`, stable panel identity, and
  accessibility live-region semantics where appropriate.
- **Reduced motion:** Immediate appearance or a short opacity change; full text,
  icon, color, and semantics remain.

### Rejected opportunities

- Animate every speed-chart or telemetry sample: too frequent and destabilizes
  functional data.
- Stagger list rows after refresh, filtering, or probing: repeats motion during
  routine work and obscures list continuity.
- Add full-screen bottom-tab transitions: the Material indicator already provides
  selection feedback and the current top-level navigation is activity-based.
- Add universal button press scaling: Material ripple already acknowledges touch.
- Add a continuous connected pulse or glow: it consumes attention and power
  without adding state information.

## 26. Implementation Priority

1. **P0:** Implement and validate connection lifecycle continuity by itself.
2. **P1:** Add real startup milestone motion after the P0 state transition is
   stable.
3. **P1:** Validate the shared selection/state pattern on one node interaction,
   then apply it to profile activation only if it remains consistent.
4. **P1:** Establish a reusable branch-transition pattern on one state container.
5. **P2:** Add occasional inline feedback transitions only where the message has
   stable identity and accessible semantics.

Do not implement all opportunities in one change. Every implementation should
include before/after evidence, reduced-motion behavior, and performance review.

## 27. Review Checklist

Before approving motion, verify:

- [ ] The interaction has a named comprehension, feedback, hierarchy, continuity,
      or trust purpose.
- [ ] The target derives from the latest real application state.
- [ ] A newer state or touch can interrupt/retarget the animation safely.
- [ ] No business action, navigation, or state report waits for completion.
- [ ] Duration, easing, spring, and travel use canonical semantic tokens.
- [ ] The smallest suitable Material/Compose API was chosen.
- [ ] `AnimatedContent`/visibility keys represent visual branches, not every data
      object.
- [ ] The transition works at Android animation scale `0×`, `1×`, and `10×`.
- [ ] Text, icon, color, semantics, and action state still communicate the result
      with motion removed.
- [ ] TalkBack order, focus, live regions, and minimum touch targets remain valid.
- [ ] Long text, large font scale, compact windows, light theme, and dark theme do
      not clip or flash.
- [ ] Lazy lists, charts, logs, and high-frequency network data remain stable.
- [ ] The animation avoids unnecessary recomposition/layout and is profiled where
      risk is non-trivial.
- [ ] No new runtime dependency was added without a concrete reviewed need.
- [ ] Previews/tests cover settled states; timing-sensitive tests use controlled
      animation time rather than sleeps.

## 28. Agent Skill Workflow

The project-local Agent Skills under `.agents/skills` support this sequence:

```text
find-animation-opportunities
→ motion-design
→ animate
→ review-animations
→ improve-animations
```

- `find-animation-opportunities` decides whether motion deserves to exist.
- `motion-design` defines intent, hierarchy, timing, easing, and choreography.
- `animate` implements one approved opportunity.
- `review-animations` performs implementation quality review.
- `improve-animations` refines an already coherent system.

For Compose implementation, also use `compose-animations`,
`compose-performance`, `compose-state-and-effects`, and
`compose-component-design`. `compose-expert` is supplementary. Installing these
Agent Skills does not add app runtime dependencies and does not authorize an
animation implementation by itself.
