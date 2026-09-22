import Foundation

/// A bookmark's routine category: the kind of everyday site it is, not what
/// it's about. Used to curate the "Routine" folder.
nonisolated enum RoutineCategory: Sendable {
    case personal
    case work
}

/// How confidently a bookmark was matched. Higher tiers win ties when more
/// than 20 bookmarks qualify for "Routine".
nonisolated enum RoutineMatchStrength: Int, Comparable, Sendable {
    case titleKeyword
    case hostKeyword
    case hostExact

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated struct RoutineMatch: Sendable, Equatable {
    let category: RoutineCategory
    let strength: RoutineMatchStrength
    /// Short human-readable reason shown in the plan preview, e.g. "Banking".
    let label: String
}

/// Classifies a bookmark as a personal- or work-routine site using a static,
/// curated, on-device table. No network calls, no machine learning: everyday
/// sites people check constantly (banking, shopping, travel, incident
/// response, cloud consoles, …) tend to live on a small, well-known set of
/// domains, or on self-hosted tools whose hostnames still carry the product
/// name. Deliberately excludes multi-purpose domains (e.g. github.com) that
/// would produce too many false positives from host matching alone.
nonisolated enum RoutineClassifier {
    private struct Entry {
        let category: RoutineCategory
        let label: String
    }

    /// Full host, or the registrable domain suffix, mapped to its category.
    /// Matched against `host` and `host`'s dot-separated suffixes.
    private static let hostExactTable: [String: Entry] = {
        var table: [String: Entry] = [:]
        func add(_ hosts: [String], _ category: RoutineCategory, _ label: String) {
            for host in hosts { table[host] = Entry(category: category, label: label) }
        }

        add(["amazon.com", "target.com", "walmart.com", "costco.com", "ebay.com", "etsy.com", "bestbuy.com"], .personal, "Shopping")
        add(["chase.com", "bankofamerica.com", "wellsfargo.com", "citibank.com", "capitalone.com", "americanexpress.com", "discover.com", "paypal.com", "venmo.com", "fidelity.com", "schwab.com", "vanguard.com"], .personal, "Banking")
        add(["geico.com", "progressive.com", "statefarm.com", "allstate.com", "libertymutual.com", "usaa.com", "healthcare.gov"], .personal, "Insurance")
        add(["kaiserpermanente.org", "zocdoc.com", "cvs.com", "walgreens.com", "goodrx.com"], .personal, "Health")
        add(["united.com", "delta.com", "aa.com", "southwest.com", "jetblue.com", "alaskaair.com", "expedia.com", "booking.com", "airbnb.com", "marriott.com", "hilton.com", "hyatt.com", "kayak.com"], .personal, "Travel")

        add(["pagerduty.com", "opsgenie.com", "datadoghq.com", "sentry.io", "newrelic.com", "honeycomb.io", "statuspage.io"], .work, "Incident Response")
        add(["console.aws.amazon.com", "portal.azure.com", "console.cloud.google.com", "app.terraform.io", "digitalocean.com", "heroku.com"], .work, "Cloud Console")
        add(["atlassian.net", "linear.app", "asana.com", "monday.com", "notion.so", "slack.com", "zoom.us"], .work, "Work Collaboration")
        return table
    }()

    /// Host *substrings* for self-hosted tools that are typically deployed on
    /// arbitrary or internal subdomains, so an exact-domain table can't cover
    /// them.
    private static let hostKeywordTable: [String: Entry] = [
        "grafana": Entry(category: .work, label: "Observability"),
        "jenkins": Entry(category: .work, label: "CI/CD"),
        "kibana": Entry(category: .work, label: "Observability"),
        "jira": Entry(category: .work, label: "Work Collaboration"),
        "confluence": Entry(category: .work, label: "Work Collaboration"),
        "terraform": Entry(category: .work, label: "Cloud Console"),
    ]

    /// Weakest signal: title substrings for cases where the host alone is
    /// ambiguous. Kept deliberately small to bound false positives.
    private static let titleKeywordTable: [String: Entry] = [
        "mychart": Entry(category: .personal, label: "Health"),
        "patient portal": Entry(category: .personal, label: "Health"),
        "boarding pass": Entry(category: .personal, label: "Travel"),
    ]

    static func classify(url: String?, title: String) -> RoutineMatch? {
        let host = url.flatMap(normalizedHost)
        let lowerTitle = title.lowercased()

        if let host {
            if let entry = hostExactTable[host] ?? registrableSuffixMatch(host) {
                return RoutineMatch(category: entry.category, strength: .hostExact, label: entry.label)
            }
            for (keyword, entry) in hostKeywordTable where host.contains(keyword) {
                return RoutineMatch(category: entry.category, strength: .hostKeyword, label: entry.label)
            }
        }

        for (keyword, entry) in titleKeywordTable where lowerTitle.contains(keyword) {
            return RoutineMatch(category: entry.category, strength: .titleKeyword, label: entry.label)
        }

        return nil
    }

    /// Matches `host` against the table by its registrable-domain suffix
    /// (e.g. `console.aws.amazon.com` isn't itself a key, but the table's
    /// `atlassian.net` entry should still match `team.atlassian.net`).
    private static func registrableSuffixMatch(_ host: String) -> Entry? {
        let labels = host.split(separator: ".")
        guard labels.count > 1 else { return nil }
        for start in 0..<(labels.count - 1) {
            let suffix = labels[start...].joined(separator: ".")
            if let entry = hostExactTable[suffix] { return entry }
        }
        return nil
    }

    private static func normalizedHost(_ urlString: String) -> String? {
        guard var host = URLComponents(string: urlString)?.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
