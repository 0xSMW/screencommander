import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import ScreenCommander

final class ObserverPerformanceTests: XCTestCase {
    private func cfString(_ value: String) -> CFString {
        CFStringCreateWithCString(nil, value, CFStringBuiltInEncodings.UTF8.rawValue)
    }

    private func fixture(
        role: String? = "AXTextField",
        value: String? = "A long observed value",
        enabled: CFTypeRef? = kCFBooleanFalse,
        focused: CFTypeRef? = kCFBooleanTrue
    ) -> [CFTypeRef?] {
        [
            role.map(cfString),
            cfString("AXSearchField"),
            cfString("Search"),
            value.map(cfString),
            cfString("Search the document"),
            enabled,
            focused
        ]
    }

    /// Mirrors the former callback's individual reads, including its value-first
    /// order, for static fixture comparison and the opt-in local A/B measurement.
    private func baselineRecord(
        maxValueLength: Int,
        attribute: (String) -> CFTypeRef?,
        actions: () -> [String],
        frame: () -> CGRect?
    ) -> AXElementRecord {
        func string(_ name: String) -> String? {
            attribute(name).flatMap(AXElement.coerceToString)
        }
        func bool(_ name: String) -> Bool? {
            guard let ref = attribute(name), CFGetTypeID(ref) == CFBooleanGetTypeID() else {
                return nil
            }
            return CFBooleanGetValue(ref as! CFBoolean)
        }

        var value = string(kAXValueAttribute)
        var valueTruncated: Bool?
        if let fullValue = value {
            let (shortened, truncated) = AXElementRecord.truncatedValue(fullValue, maxLength: maxValueLength)
            value = shortened
            if truncated { valueTruncated = true }
        }
        return AXElementRecord(
            id: "",
            role: string(kAXRoleAttribute) ?? "AXUnknown",
            subrole: string(kAXSubroleAttribute),
            title: string(kAXTitleAttribute),
            value: value,
            valueTruncated: valueTruncated,
            description: string(kAXDescriptionAttribute),
            enabled: bool(kAXEnabledAttribute) ?? true,
            focused: bool(kAXFocusedAttribute),
            actions: actions(),
            boundsPoints: frame().map(RectD.init),
            boundsPixels: nil
        )
    }

    func testBatchedRecordMatchesFormerIndividualReads() {
        let fallbackFrame = CGRect(x: 12, y: 34, width: 56, height: 78)
        let fixtures = [
            fixture(),
            fixture(role: nil, value: nil, enabled: nil, focused: nil),
            fixture(value: "short", enabled: cfString("true"), focused: nil)
        ]

        for values in fixtures {
            let attributes = Dictionary(uniqueKeysWithValues: zip(ObserverRecordHydrator.attributeNames, values).map { ($0.0, $0.1) })
            let expected = baselineRecord(
                maxValueLength: 5,
                attribute: { attributes[$0] ?? nil },
                actions: { ["AXPress", "AXShowMenu"] },
                frame: { fallbackFrame }
            )
            let actual = ObserverRecordHydrator.makeRecord(
                maxValueLength: 5,
                attributeValues: { names in names.map { attributes[$0] ?? nil } },
                actionNames: { ["AXPress", "AXShowMenu"] },
                frame: { fallbackFrame }
            )
            XCTAssertEqual(actual, expected)
        }
    }

    func testHydrationUsesOneBatchAndPreservesFrameFallbackResult() {
        let values = fixture()
        var batchCalls = 0
        var actionCalls = 0
        var frameCalls = 0
        let positionSizeFallback = CGRect(x: 101, y: 202, width: 303, height: 404)

        let record = ObserverRecordHydrator.makeRecord(
            maxValueLength: 200,
            attributeValues: { names in
                batchCalls += 1
                XCTAssertEqual(names, ObserverRecordHydrator.attributeNames)
                return values
            },
            actionNames: {
                actionCalls += 1
                return ["AXPress"]
            },
            frame: {
                frameCalls += 1
                return positionSizeFallback
            }
        )

        XCTAssertEqual(batchCalls, 1)
        XCTAssertEqual(actionCalls, 1)
        XCTAssertEqual(frameCalls, 1)
        XCTAssertEqual(record.boundsPoints, RectD(positionSizeFallback))
        XCTAssertEqual(record.value, "A long observed value")
        XCTAssertEqual(record.enabled, false)
    }

    /// Opt in with SCREENCOMMANDER_PERF_AB=1. Measures local fixture hydration only;
    /// request counts are IPC-equivalent boundaries, not remote AX timing estimates.
    func testObserverHydrationABBenchmark() throws {
        guard ProcessInfo.processInfo.environment["SCREENCOMMANDER_PERF_AB"] == "1" else {
            throw XCTSkip("Set SCREENCOMMANDER_PERF_AB=1 for the local observer hydration A/B benchmark")
        }

        let values = fixture()
        let attributes = Dictionary(uniqueKeysWithValues: zip(ObserverRecordHydrator.attributeNames, values).map { ($0.0, $0.1) })
        let iterations = 10_000
        var baselineAttributeCalls = 0
        var optimizedBatchCalls = 0
        var checksum = 0
        let bounds = CGRect(x: 1, y: 2, width: 3, height: 4)

        let baselineStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            let record = baselineRecord(
                maxValueLength: 200,
                attribute: { name in
                    baselineAttributeCalls += 1
                    return attributes[name] ?? nil
                },
                actions: { ["AXPress"] },
                frame: { bounds }
            )
            checksum += record.value?.count ?? 0
        }
        let baselineNanoseconds = DispatchTime.now().uptimeNanoseconds - baselineStart

        let optimizedStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            let record = ObserverRecordHydrator.makeRecord(
                maxValueLength: 200,
                attributeValues: { names in
                    optimizedBatchCalls += 1
                    return names.map { attributes[$0] ?? nil }
                },
                actionNames: { ["AXPress"] },
                frame: { bounds }
            )
            checksum += record.value?.count ?? 0
        }
        let optimizedNanoseconds = DispatchTime.now().uptimeNanoseconds - optimizedStart

        XCTAssertEqual(baselineAttributeCalls, iterations * 7)
        XCTAssertEqual(optimizedBatchCalls, iterations)
        XCTAssertEqual(checksum, iterations * 2 * "A long observed value".count)

        let report: [String: Any] = [
            "benchmark": "observer_hydration_ab",
            "scope": "local_fixture_no_remote_ipc",
            "iterations_per_variant": iterations,
            "baseline_local_nanoseconds": baselineNanoseconds,
            "optimized_local_nanoseconds": optimizedNanoseconds,
            "baseline_scalar_attribute_calls": baselineAttributeCalls,
            "optimized_batch_attribute_calls": optimizedBatchCalls,
            "other_calls_per_record": ["actions": 1, "frame": 1]
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("SC_PERF_AB \(String(decoding: data, as: UTF8.self))")
    }

    /// Run only against an explicitly supplied, stable app window. This times real
    /// AX record hydration; it does not measure observer event delivery or callbacks.
    func testLiveWindowObserverHydrationABBenchmark() throws {
        guard let rawPID = ProcessInfo.processInfo.environment["SCREENCOMMANDER_PERF_APP_PID"] else {
            throw XCTSkip("Set SCREENCOMMANDER_PERF_APP_PID to opt in to real AX window reads")
        }
        let pid = try XCTUnwrap(pid_t(rawPID), "SCREENCOMMANDER_PERF_APP_PID must be a valid PID")
        let element = try XCTUnwrap(AXElement.application(pid: pid).windows.first,
                                    "The supplied app must expose a stable AX window")

        func legacy() -> AXElementRecord {
            baselineRecord(maxValueLength: 200,
                           attribute: { element.copyAttribute($0) },
                           actions: { element.actionNames },
                           frame: { element.frame })
        }
        func batched() -> AXElementRecord {
            ObserverRecordHydrator.makeRecord(maxValueLength: 200,
                                              attributeValues: { element.attributeValues($0) },
                                              actionNames: { element.actionNames },
                                              frame: { element.frame })
        }
        func timed(_ read: () -> AXElementRecord) -> (record: AXElementRecord, nanoseconds: UInt64) {
            let start = DispatchTime.now().uptimeNanoseconds
            let record = read()
            return (record, DispatchTime.now().uptimeNanoseconds - start)
        }
        func nearestRank(_ samples: [UInt64], percent: Int) -> UInt64 {
            let sorted = samples.sorted()
            let index = max(0, (sorted.count * percent + 99) / 100 - 1)
            return sorted[index]
        }

        let warmupPairs = 3
        let measuredPairs = 20
        var legacyTimes: [UInt64] = []
        var batchedTimes: [UInt64] = []
        for pair in 0..<(warmupPairs + measuredPairs) {
            // Alternate order so first-read caching benefits both variants.
            let legacyFirst = pair.isMultiple(of: 2)
            let first = timed { legacyFirst ? legacy() : batched() }
            let second = timed { legacyFirst ? batched() : legacy() }
            let old = legacyFirst ? first : second
            let new = legacyFirst ? second : first
            guard old.record == new.record else {
                XCTFail("The live AX window changed between reads or hydration differed at pair \(pair)")
                return
            }
            if pair >= warmupPairs {
                legacyTimes.append(old.nanoseconds)
                batchedTimes.append(new.nanoseconds)
            }
        }

        let report: [String: Any] = [
            "benchmark": "observer_hydration_live_window_ab",
            "scope": "real_ax_window_record_reads_only_no_event_delivery",
            "pid": pid,
            "warmup_pairs": warmupPairs,
            "measured_pairs": measuredPairs,
            "order": "alternating_legacy_first_batched_first",
            "record_equivalence": true,
            "legacy_p50_nanoseconds": nearestRank(legacyTimes, percent: 50),
            "legacy_p95_nanoseconds": nearestRank(legacyTimes, percent: 95),
            "batched_p50_nanoseconds": nearestRank(batchedTimes, percent: 50),
            "batched_p95_nanoseconds": nearestRank(batchedTimes, percent: 95)
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("SC_PERF_AB \(String(decoding: data, as: UTF8.self))")
    }
}
