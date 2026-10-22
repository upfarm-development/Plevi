import Foundation
import Testing
@testable import PleviDomain

@Suite("The watch choosing its server address again (watch-01)")
struct WatchEndpointRefreshTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    /// `#expect` cannot call a mutating member, so the call is made here.
    private func admit(
        _ gate: inout EndpointRefreshGate,
        _ trigger: EndpointRefreshGate.Trigger,
        after seconds: TimeInterval = 0,
        alternative: Bool = true
    ) -> Bool {
        gate.admit(trigger, hasAlternativeAddress: alternative, now: t0.addingTimeInterval(seconds))
    }

    @Test("A path change or a return to the foreground always runs")
    func pathAndForegroundRun() {
        var gate = EndpointRefreshGate()
        #expect(admit(&gate, .pathChange))
        // Straight after: still allowed. The caller coalesces overlapping runs;
        // the gate does not hold back the signals that mean the world changed.
        #expect(admit(&gate, .pathChange, after: 1))
        #expect(admit(&gate, .foreground, after: 2))
    }

    @Test("A failure is throttled against the last refresh of any kind")
    func failureThrottled() {
        var gate = EndpointRefreshGate(failureInterval: 30)
        #expect(admit(&gate, .failure))
        #expect(!admit(&gate, .failure, after: 10))
        #expect(admit(&gate, .failure, after: 31))
    }

    @Test("A path change starts the failure window")
    func pathChangeStartsTheWindow() {
        var gate = EndpointRefreshGate(failureInterval: 30)
        #expect(admit(&gate, .pathChange))
        // A server that is down fails every song; one probe after the path
        // change already told us where the address stands.
        #expect(!admit(&gate, .failure, after: 5))
    }

    @Test("A refused refresh does not start the window")
    func refusedDoesNotCount() {
        var gate = EndpointRefreshGate(failureInterval: 30)
        #expect(admit(&gate, .pathChange))
        #expect(!admit(&gate, .failure, after: 20))
        // 31 s after the last run, not 11 s after the refused failure.
        #expect(admit(&gate, .failure, after: 31))
    }

    @Test("A single-address server never probes")
    func singleAddress() {
        var gate = EndpointRefreshGate()
        for trigger in [EndpointRefreshGate.Trigger.foreground, .pathChange, .failure] {
            #expect(!admit(&gate, trigger, alternative: false))
        }
    }
}
