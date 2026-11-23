import Foundation

@main struct DisplayModeRunner {
    static func main() {
        let expect: (Bool, String) -> Void = { precondition($0, $1) }
        DisplayModeChecks.classification(expect: expect)
        DisplayModeChecks.configuration(expect: expect)
        DisplayModeChecks.model(expect: expect)
        DisplayModeChecks.mainDisplayConfiguration(expect: expect)
        DisplayModeChecks.mainDisplayModel(expect: expect)
        DisplayModeChecks.arrangementTransaction(expect: expect)
        DisplayModeChecks.switchRipples(expect: expect)
        print("Display mode checks passed: main display selection with relative layout, mixed topology, per-display requests, dependency guards, failures, readback, timeout, hot-plug selection and switch ripples.")
    }
}
