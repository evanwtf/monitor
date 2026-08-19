import Foundation
import MonitorCore

/// Where the layout choices are kept between launches.
///
/// `UserDefaults`, which is the one place a Mac app is expected to write. Note
/// what this is not: the app still writes no *history* to disk, and still does
/// not link `MonitorStore`. The argument against storing samples is about SSD
/// endurance — a monitor runs all day, and a sample every half second forever
/// costs real writes. A checkbox written when somebody ticks it costs nothing,
/// and the alternative is a preferences pane that forgets.
public enum LayoutPreferencesStore {
    static let key = "layout.preferences"

    /// Named explicitly rather than taken from `.standard`.
    ///
    /// `.standard` keys off the bundle identifier, and `swift run monitor` has
    /// no bundle: the development build would write to a domain called
    /// `monitor` and `monitor.app` to `wtf.evan.monitor`, so a layout chosen in
    /// one would be invisible in the other. Same reasoning as the version
    /// string — the two builds are the same program and must not disagree.
    /// Computed rather than stored because a `static let` holding a
    /// non-`Sendable` class is a concurrency error under Swift 6, and
    /// `UserDefaults` is cheap to ask for and shared behind the scenes anyway.
    public static var suite: UserDefaults { UserDefaults(suiteName: domain) ?? .standard }

    static let domain = "wtf.evan.monitor"

    /// Reads the stored layout and gives any metric it has not seen its
    /// default. A first launch, a corrupt value and a missing key all end up
    /// in the same place: the defaults for whatever this machine reports.
    static func load(
        for descriptors: [MetricDescriptor], from defaults: UserDefaults = suite
    ) -> LayoutPreferences {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(LayoutPreferences.self, from: data)
        else {
            return LayoutPreferences.defaults(for: descriptors)
        }
        return stored.adoptingDefaults(for: descriptors)
    }

    static func save(_ preferences: LayoutPreferences, to defaults: UserDefaults = suite) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            log.error("Could not encode layout preferences")
            return
        }
        defaults.set(data, forKey: key)
    }
}

/// The sampling rates, kept beside the layout in the same domain.
enum SamplingPreferencesStore {
    static let key = "sampling.preferences"

    static func load(from defaults: UserDefaults = LayoutPreferencesStore.suite)
        -> SamplingPreferences
    {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(SamplingPreferences.self, from: data)
        else {
            return .default
        }
        return stored
    }

    static func save(
        _ preferences: SamplingPreferences,
        to defaults: UserDefaults = LayoutPreferencesStore.suite
    ) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            log.error("Could not encode sampling preferences")
            return
        }
        defaults.set(data, forKey: key)
    }
}

/// Where the arrangement is kept: the same domain, its own key.
///
/// Its own key rather than a field on the layout, because the two answer
/// different questions — `LayoutPreferences` is what is drawn, `PanelArrangement`
/// is where it sits and how big it is. Separate keys mean a value this version
/// cannot read costs one of them and not both.
///
/// This is still the documented exception to "the app writes nothing to disk":
/// a write when somebody moves a card or lets go of a slider, not a write every
/// half second forever. **Save on gesture end, never during** — a slider dragged
/// across its travel fires continuously, and persisting each change would turn
/// one decision into a per-frame write.
enum PanelArrangementStore {
    static let key = "panel.arrangement"

    /// A first launch, a corrupt value and a missing key all end up in the same
    /// place: the defaults for whatever this machine reports.
    static func load(
        for descriptors: [MetricDescriptor],
        from defaults: UserDefaults = LayoutPreferencesStore.suite
    ) -> PanelArrangement {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(PanelArrangement.self, from: data)
        else {
            return PanelArrangement.defaults(for: descriptors)
        }
        return stored.adoptingDefaults(for: descriptors)
    }

    static func save(
        _ arrangement: PanelArrangement,
        to defaults: UserDefaults = LayoutPreferencesStore.suite
    ) {
        guard let data = try? JSONEncoder().encode(arrangement) else {
            log.error("Could not encode panel arrangement")
            return
        }
        defaults.set(data, forKey: key)
    }
}

/// How the charts are drawn, kept beside the layout in the same domain.
///
/// Its own key, for the same reason the arrangement has one: `LayoutPreferences`
/// is which cards exist and this is how one of them is drawn. A value a later
/// version writes costs one of them and not both.
enum ChartPreferencesStore {
    static let key = "chart.preferences"

    static func load(from defaults: UserDefaults = LayoutPreferencesStore.suite)
        -> ChartPreferences
    {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(ChartPreferences.self, from: data)
        else {
            return .default
        }
        return stored
    }

    static func save(
        _ preferences: ChartPreferences,
        to defaults: UserDefaults = LayoutPreferencesStore.suite
    ) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            log.error("Could not encode chart preferences")
            return
        }
        defaults.set(data, forKey: key)
    }
}
