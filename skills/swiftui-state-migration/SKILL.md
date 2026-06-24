---
name: swiftui-state-migration
description: Migrate SwiftUI view state to the Observation framework (@Observable / @Bindable)
---

# SwiftUI State Migration (Observation framework)

Migrate `ObservableObject`-based view models to the `@Observable` macro introduced
with the Observation framework.

## When this applies
- A type conforms to `ObservableObject` and publishes via `@Published`.
- Views hold it with `@StateObject` / `@ObservedObject` / `@EnvironmentObject`.

## Steps
1. Replace `class Model: ObservableObject` with `@Observable class Model`.
2. Remove `@Published` from stored properties (tracking is automatic).
3. In views, replace `@StateObject var model = Model()` with `@State var model = Model()`.
4. Replace `@ObservedObject var model` with plain `var model` (or `@Bindable` when
   you need bindings).
5. Replace `@EnvironmentObject var model` with `@Environment(Model.self) var model`,
   and inject with `.environment(model)` instead of `.environmentObject(model)`.

## Verify
- `xcode build` succeeds.
- Bindings (`$model.value`) still compile — use `@Bindable` where needed.
