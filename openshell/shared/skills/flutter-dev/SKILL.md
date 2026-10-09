---
name: flutter-dev
description: Flutter and Dart engineering - widget design, state management, rebuild scope, lifecycle and async hygiene, platform concerns, pub/analyze/test tooling. Use when writing, reviewing, or debugging Flutter or Dart code, pubspec.yaml, or Flutter tests.
---

# Flutter / Dart engineering

Treat every task as production Flutter work: repo first, then widgets, then tests, then platform concerns.

## Read the repo before writing code

Check `pubspec.yaml` (SDK + package versions), `analysis_options.yaml` (strict-casts / strict-inference / lints), `lib/`, `test/`, `integration_test/`, and platform folders (`android/`, `ios/`, `web/`, `linux/`). Match the project's existing structure, naming, and state-management approach. Do not introduce a competing framework into an established one.

## Never invent Flutter APIs

Widget names, constructor parameters, lifecycle order, and package versions must come from Context7 (`Flutter`, `Dart`, `Firebase`, `Riverpod`, `Bloc`, `GetIt`, `go_router`, ...) or the SDK actually vendored in the repo. Flutter's surface changes every stable release; a plausible-looking widget is not an existing one.

## Composition over cleverness

- Small widgets, explicit `const` constructors, no giant `build()` methods.
- Separate layout from business logic; if the project already has a view-model/controller/repository layer, keep state there rather than hiding it in a widget.
- Follow the repo's existing state-management choice (`Provider`, `Riverpod`, `Bloc`, `ValueNotifier`, plain `setState`). If there is none, propose the smallest option that works and say that you proposed it.

## Widget identity and rebuild scope

When the bug is "it does not update" or "the whole list re-renders", reason about rebuild scope first: `Key`/`ValueKey`/`UniqueKey`, `const` subtrees, `InheritedWidget` dependencies, which subtree a `setState` invalidates. Reach for `AnimatedSwitcher`/`RepaintBoundary`/slivers only after that diagnosis.

## Tests are part of the feature

- Widget tests for layout and interaction; `flutter_test` unit tests for logic.
- Hand-written fakes or `mockito` mocks instead of real network/plugin calls.
- Golden tests only when the project already uses them.
- New behavior without a test is unfinished.

## Async and lifecycle hygiene

Await every future; no unawaited futures in `build()`. Dispose controllers, animations, subscriptions, and stream listeners in `dispose()`. Never call `setState` after dispose or after an `await` without a `mounted` check. Cancel `Stream`/`async*` work when the widget goes away.

## Platform awareness

Material vs Cupertino intent, text direction/RTL, safe-area padding, keyboard and scroll physics on web, plugin platform support declared in `pubspec.yaml`, and permissions/Info.plist/AndroidManifest entries for anything native. Say explicitly when a change requires editing a platform folder, not only Dart.

## Performance

Avoid per-frame allocations in `build()`. Use `ListView.builder`/slivers for long lists, `RepaintBoundary` around isolated animation, `const` where it prevents rebuilds, isolates for heavy work. Measure (DevTools timeline, `Profile` mode) before optimizing.

## Tooling

Run when the toolchain is present; state what could not be verified when it is not:

```sh
dart format .
flutter analyze --fatal-infos
dart fix --apply
flutter test --coverage
flutter pub get
flutter pub upgrade --major-versions
```

Never claim tests or analysis passed without running them.

## Dart quality bar

`final` by default, explicit null safety (`!` only with justification), no `dynamic` leaking through public APIs, doc comments on exported members, records/patterns where they genuinely simplify.
