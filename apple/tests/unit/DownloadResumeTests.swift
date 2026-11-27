import Foundation
import HTTPTypes
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

/// A waiting title is claimed on the next chance whatever else went wrong meanwhile: no sync step
/// that fails or is cut short, and no pump asked for while one runs, leaves it waiting for good.
extension DownloadStoreTests {
    /// Title 20 waits unclaimed, as after a batch the server refused for the moment.
    private func waitingUnclaimed(_ id: UID) async throws {
        harness.resolves["item/\(id)"] = [Fixtures.downloadTitle(id, "movie")]
        let answer = harness.transport.respond
        harness.transport.respond = {
            $0.path.hasSuffix("/downloads/batch") ? (.notFound, Fixtures.error("not_found")) : answer?($0)
        }
        try await harness.download(.title(id))
        harness.transport.respond = answer
        XCTAssertEqual(store.titles[id]?.state, .pending)
        XCTAssertNil(store.titles[id]?.claim)
    }

    private func becomesOnDevice(_ id: UID) async throws {
        for _ in 0..<1000 where store.titles[id]?.state != .onDevice { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(store.titles[id]?.state, .onDevice)
    }

    func testASyncWhoseStandingRequestFailsStillFetchesWhatWaits() async throws {
        harness.resolves["item/\(UID.n(10))"] = [Fixtures.downloadTitle(101, "episode")]
        try await harness.download(.show(10))
        try await waitingUnclaimed(20)
        let answer = harness.transport.respond
        harness.transport.respond = {
            $0.path == "/profiles/\(UID.n(1))/downloads/resolve"
                ? (.internalServerError, Fixtures.error("internal")) : answer?($0)
        }
        await store.sync(profile: 1)
        try await becomesOnDevice(20)
    }

    func testASyncCutShortStillFetchesWhatWaits() async throws {
        harness.resolves["item/\(UID.n(10))"] = [Fixtures.downloadTitle(101, "episode")]
        try await harness.download(.show(10))
        try await waitingUnclaimed(20)
        let gate = Gate()
        harness.transport.hold = { sent in
            if sent.path == "/profiles/\(UID.n(1))/downloads/resolve" { try await gate.wait() }
        }
        let sync = Task { await store.sync(profile: 1) }
        for _ in 0..<500 where !harness.transport.paths(.post).contains("/profiles/\(UID.n(1))/downloads/resolve") {
            try await Task.sleep(for: .milliseconds(2))
        }
        // As SwiftUI cancels a view's task when the scene goes inactive.
        sync.cancel()
        await sync.value
        harness.transport.hold = nil
        try await becomesOnDevice(20)
    }

    func testATitleAskedForWhileAPumpClaimsIsClaimedRightAfter() async throws {
        harness.resolves["item/\(UID.n(20))"] = [Fixtures.downloadTitle(20, "movie")]
        harness.resolves["item/\(UID.n(21))"] = [Fixtures.downloadTitle(21, "movie")]
        let gate = Gate()
        harness.transport.hold = { sent in if sent.path.hasSuffix("/downloads/batch") { try await gate.wait() } }
        _ = try await store.request(.title(20), quality: .original, profile: 1)
        for _ in 0..<500 where !store.pumping { try await Task.sleep(for: .milliseconds(2)) }
        _ = try await store.request(.title(21), quality: .original, profile: 1)
        gate.open()
        try await becomesOnDevice(20)
        try await becomesOnDevice(21)
    }

    /// Another adult is active: the server answers for them and their household's kids alone.
    private func activate(_ active: UID) async throws {
        let quinn = Fixtures.account(4, "Quinn")
        try harness.keep(
            me: Fixtures.me
                .replacingOccurrences(
                    of: #""activeProfileId":"\#(UID.n(1))""#, with: #""activeProfileId":"\#(active)""#
                )
                .replacingOccurrences(
                    of: #""profiles":[\#(Fixtures.adult),"#, with: #""profiles":[\#(Fixtures.adult),\#(quinn),"#))
        let answer = harness.server.answer
        harness.transport.respond = { sent in
            let profile = UID(String(sent.path.split(separator: "/").dropFirst().first ?? ""))
            let mine = profile == active || profile == 2
            return sent.path.hasPrefix("/profiles/") && !mine ? (.notFound, Fixtures.error("not_found")) : answer(sent)
        }
    }

    func testATitleIsClaimedAsTheActiveProfileOrAKidAndAnotherAdultsWaitsForThem() async throws {
        for id in [30, 31, 32] { harness.resolves["item/\(UID.n(id))"] = [Fixtures.downloadTitle(UID.n(id), "movie")] }
        // Quinn asks while the server turns the device away for now.
        try await activate(4)
        let quinns = harness.transport.respond
        harness.transport.respond = {
            $0.path.hasSuffix("/downloads/batch") ? (.forbidden, Fixtures.error("forbidden")) : quinns?($0)
        }
        try await harness.download(.title(30), profile: 4)
        try await harness.download(.title(31), profile: 4)
        try await activate(1)
        let before = harness.transport.paths(.post).filter { $0 == "/profiles/\(UID.n(4))/downloads/batch" }.count
        try await harness.download(.title(30), profile: 1)
        try await harness.download(.title(32), profile: 2)

        XCTAssertEqual(store.titles[30]?.state, .onDevice, "a title Avery asked for too is claimed as Avery")
        XCTAssertEqual(store.titles[32]?.state, .onDevice, "an adult may claim for a kid")
        XCTAssertEqual(store.titles[31]?.state, .pending)
        let after = harness.transport.paths(.post).filter { $0 == "/profiles/\(UID.n(4))/downloads/batch" }.count
        XCTAssertEqual(after, before, "nothing is asked for Quinn while Avery is active")

        try await activate(4)
        await store.sync(profile: 4)
        try await becomesOnDevice(31)
    }

    func testAnotherAdultsClaimWaitsForThemRatherThanBeingDropped() async throws {
        harness.resolves["item/\(UID.n(33))"] = [Fixtures.downloadTitle(33, "movie")]
        try await activate(4)
        let gate = Gate()
        harness.downloader.onFetch = { _ in try? await gate.wait() }
        let fetching = Task { try await harness.download(.title(33), profile: 4) }
        for _ in 0..<500 where harness.downloader.requests.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        // Avery takes over before the file lands: the claim is Quinn's, so it waits for Quinn.
        try await activate(1)
        gate.open()
        _ = try await fetching.value
        let claim = try XCTUnwrap(store.titles[33]?.claim)
        XCTAssertEqual(claim.profileId, 4)

        try await activate(4)
        await store.sync(profile: 4)
        try await becomesOnDevice(33)
        XCTAssertEqual(
            harness.transport.paths(.delete), ["/profiles/\(UID.n(4))/downloads/\(claim.id)"], "released as Quinn")
    }

    func testTheLibrariesAreTheReplicasByName() async throws {
        try await harness.replica.write { db in
            try db.library(1, "tv")
            try db.library(3, "movies")
        }
        await store.loadLibraries()
        let tv = DownloadLibrary(id: 1, name: "Tv", kind: .tv)
        XCTAssertEqual(store.libraries, [DownloadLibrary(id: 3, name: "Movies", kind: .movies), tv])
        XCTAssertFalse(store.settings(1).keeps(tv), "TV removes watched titles by default")
    }
}
