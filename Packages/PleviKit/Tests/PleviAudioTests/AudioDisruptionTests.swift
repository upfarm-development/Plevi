import Testing
@testable import PleviAudio

@Suite("Surviving what the audio system does to us")
struct AudioDisruptionTests {
    // MARK: The output going away

    @Test("Headphones out pauses rather than switching to the speaker")
    func headphonesOut() {
        #expect(
            AudioDisruptionPolicy.recovery(for: .outputDisappeared, isPlaying: true) == .pause
        )
    }

    @Test("Headphones out while paused changes nothing")
    func headphonesOutWhilePaused() {
        // Without this a disconnect would announce a pause that never
        // happened, and the Lock Screen would redraw for no reason.
        #expect(
            AudioDisruptionPolicy.recovery(for: .outputDisappeared, isPlaying: false) == .nothing
        )
    }

    // MARK: Interruptions

    @Test("A call pauses the music")
    func callPauses() {
        #expect(AudioDisruptionPolicy.recovery(for: .interrupted, isPlaying: true) == .pause)
    }

    @Test("The music comes back after the call")
    func resumesAfterCall() {
        let recovery = AudioDisruptionPolicy.recovery(
            for: .interruptionEnded(mayResume: true),
            isPlaying: false,
            wasPlayingBeforeInterruption: true
        )
        #expect(recovery == .resume)
    }

    @Test("A call that interrupts nothing starts nothing")
    func silenceStaysSilent() {
        // The dangerous case: a missed call while the app sits idle must not
        // start playing music by itself.
        let recovery = AudioDisruptionPolicy.recovery(
            for: .interruptionEnded(mayResume: true),
            isPlaying: false,
            wasPlayingBeforeInterruption: false
        )
        #expect(recovery == .nothing)
    }

    @Test("When the system says do not resume, we do not resume")
    func obeysTheSystem() {
        let recovery = AudioDisruptionPolicy.recovery(
            for: .interruptionEnded(mayResume: false),
            isPlaying: false,
            wasPlayingBeforeInterruption: true
        )
        #expect(recovery == .nothing)
    }

    // MARK: The graph being pulled apart

    @Test("A configuration change rebuilds and carries on playing")
    func rebuildsAndResumes() {
        let recovery = AudioDisruptionPolicy.recovery(for: .configurationChanged, isPlaying: true)
        #expect(recovery == .rebuild(resumePlaying: true))
    }

    @Test("A configuration change while paused still rebuilds")
    func rebuildsWhilePaused() {
        // The connections are broken whether or not music was playing. Skip
        // the rebuild and the *next* track has nowhere to go.
        let recovery = AudioDisruptionPolicy.recovery(for: .configurationChanged, isPlaying: false)
        #expect(recovery == .rebuild(resumePlaying: false))
    }
}
