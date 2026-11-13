import Foundation
@main struct FanRegistrationChecks {
 @MainActor static func main() async throws {
  var recovery = FanConnectionRecovery()
  let start = Date(timeIntervalSince1970: 1_000)
  precondition(recovery.canAttempt(at: start))
  for delay: TimeInterval in [2, 4, 8, 10, 10, 10, 10, 10] {
   recovery.scheduleRetry(after: start)
   precondition(!recovery.canAttempt(at: start.addingTimeInterval(delay - 0.1)))
   precondition(recovery.canAttempt(at: start.addingTimeInterval(delay)), "Failures must never exhaust recovery")
  }
  recovery.reset()
  recovery.scheduleRetry(after: start)
  precondition(recovery.canAttempt(at: start.addingTimeInterval(2)), "Success/manual retry resets backoff")
  precondition(FanConnectionRecovery.configurationTimeout >= 30, "Cold launch can take 26 seconds")
  let suite = "tactora-fan-recovery-checks"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  defer { defaults.removePersistentDomain(forName: suite) }
  var now = start, probes = 0
  let manager = FanControlManager(defaults: defaults, now: { now }, serviceEnabled: { probes += 1; return false })
  manager.setEnabled(true)
  precondition(probes == 1 && manager.enabled && !manager.active)
  for delay: TimeInterval in [2, 4, 8, 10, 10, 10, 10, 10] {
   let previous = probes
   now = now.addingTimeInterval(delay - 0.1); manager.poll()
   precondition(probes == previous, "No busy retry loop")
   now = now.addingTimeInterval(0.1); manager.poll()
   precondition(probes == previous + 1, "Manager must retry beyond three failures")
  }
  manager.setEnabled(false)
  let stopped = probes
  now = now.addingTimeInterval(600); manager.poll()
  precondition(probes == stopped && !manager.enabled, "Explicit off cancels automatic recovery")
  var events: [String] = []
  func refresh(_ previous: String?, fail: Bool = false) async throws {
   try await refreshFanHelperRegistration(previous: previous, current: "102", unregister: {
    events.append("unregister")
    if fail { throw FanControlError(message: "unregister failed") }
   }, register: { events.append("register") }, save: { events.append("save") })
  }
  try await refresh("102"); precondition(events.isEmpty)
  try await refresh("100"); precondition(events == ["unregister", "register", "save"])
  events = []; try await refresh(nil); precondition(events == ["unregister", "register", "save"])
  events = []
  do { try await refresh("100", fail: true); preconditionFailure("must fail") } catch {}
  precondition(events == ["unregister"], "Failed refresh must not record success")
  events = []
  do {
   try await refreshFanHelperRegistration(previous: "100", current: "103", unregister: { events.append("unregister") },
    register: { events.append("register"); throw FanControlError(message: "register failed") }, save: { events.append("save") })
   preconditionFailure("must fail")
  } catch {}
  precondition(events == ["unregister", "register"], "Failed registration must be retryable")
  var attempts = 0, saved = false
  try await refreshFanHelperRegistration(previous: "106", current: "107", unregister: {}, register: {
   attempts += 1
   if attempts < 3 { throw NSError(domain: "SMAppServiceErrorDomain", code: 1) }
  }, save: { saved = true })
  precondition(attempts == 3 && saved, "Retry transient registration failure after unregister")
  print("Fan helper build refresh, legacy registration and failure checks passed")
 }
}
