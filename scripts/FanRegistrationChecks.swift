import Foundation
@main struct FanRegistrationChecks {
 @MainActor static func main() async throws {
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
  print("Fan helper build refresh, legacy registration and failure checks passed")
 }
}
