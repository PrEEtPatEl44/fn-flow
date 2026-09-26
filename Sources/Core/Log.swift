import os

/// View with: log stream --level info --predicate 'subsystem == "dev.nemotronflow.app"'
/// (The subsystem matches the bundle ID, which keeps the app's original name; see Info.plist.)
let log = Logger(subsystem: "dev.nemotronflow.app", category: "flow")
