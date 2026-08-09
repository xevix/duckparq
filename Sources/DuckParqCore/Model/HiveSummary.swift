import Foundation

/// How a hive dataset is partitioned: the keys in hierarchy order, how many
/// distinct values each of them takes, and how many partitions there are.
///
/// Every fact here is spelled out in the `key=value` directory names the layout
/// is made of, so it is read from paths and nothing else. That is the whole
/// reason the inspector can show it: the same question put to the data —
/// `SELECT count(DISTINCT year), count(DISTINCT element)` — is a scan of two
/// columns over the entire dataset, which is exactly the cost the schema panel
/// exists to avoid.
///
/// The counts are per key across the whole dataset rather than within a parent
/// partition: an archive of 263 years and 144 elements has 144 elements however
/// unevenly they are spread across the years. `partitionCount` is therefore not
/// the product of them — only the combinations that exist on disk are
/// partitions, and in a real archive most of the grid is missing.
public struct HiveSummary: Sendable, Equatable {
    /// One partition key and its cardinality.
    public struct Key: Sendable, Equatable {
        /// The key as written on disk — the `year` of `year=2024/`.
        public let name: String
        /// Distinct values the key takes across the dataset. A NULL partition,
        /// which hive spells `__HIVE_DEFAULT_PARTITION__`, is one of them.
        public let distinctValues: Int

        public init(name: String, distinctValues: Int) {
            self.name = name
            self.distinctValues = distinctValues
        }
    }

    /// Outermost key first, which is the order the directories nest in.
    public let keys: [Key]
    /// Distinct combinations of key values present on disk.
    public let partitionCount: Int

    public init(keys: [Key], partitionCount: Int) {
        self.keys = keys
        self.partitionCount = partitionCount
    }

    /// Above this many files the listing is not read at all. Every number here
    /// is a distinct count over the *whole* file list, so a truncated listing
    /// would under-report all of them while looking exactly like a complete
    /// one — the same trap `HivePageIndex.build` refuses to walk into.
    public static let fileLimit = 200_000

    /// Summarise a dataset from the paths of its files.
    ///
    /// Nil for anything that is not one hive layout: a file sitting outside any
    /// `key=value` directory, or files that disagree about which keys they are
    /// partitioned by. In both cases the dataset has no single partition
    /// hierarchy to describe, and inventing one would be worse than saying
    /// nothing — the same test `HivePageIndex.build` applies before it will
    /// page a dataset by partition order.
    public static func summarize(paths: [String], under root: URL) -> HiveSummary? {
        var names: [String]?
        var valuesByLevel: [Set<String?>] = []
        var partitions: Set<[String?]> = []

        for path in paths {
            let (keys, values) = HivePageIndex.partitionComponents(of: path, under: root)
            guard !keys.isEmpty else { return nil }
            if let names {
                guard names == keys else { return nil }
            } else {
                names = keys
                valuesByLevel = Array(repeating: [], count: keys.count)
            }
            for (level, value) in values.enumerated() {
                valuesByLevel[level].insert(value)
            }
            partitions.insert(values)
        }

        guard let names, !names.isEmpty else { return nil }
        return HiveSummary(
            keys: zip(names, valuesByLevel).map { Key(name: $0, distinctValues: $1.count) },
            partitionCount: partitions.count
        )
    }
}
