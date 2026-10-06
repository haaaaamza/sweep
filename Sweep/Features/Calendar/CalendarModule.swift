import Foundation
import Combine
import EventKit
import AppKit

/// Reads upcoming events from the user's calendars (EventKit) for the island's
/// Calendar page. Read-only; events never leave the Mac.
final class CalendarModule: ObservableObject {
    static let shared = CalendarModule()

    struct Event: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let calendarColor: NSColor
        let location: String?
    }

    enum Access {
        case notDetermined
        case granted
        case denied
    }

    @Published private(set) var access: Access = .notDetermined
    @Published private(set) var events: [Event] = []

    private let store = EKEventStore()

    private init() {
        refreshAccess()
    }

    func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            access = .granted
            reload()
        case .denied, .restricted:
            access = .denied
        default:
            access = .notDetermined
        }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.access = granted ? .granted : .denied
                if granted { self.reload() }
            }
        }
    }

    func reload() {
        guard access == .granted else { return }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 86400)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let found = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(20)
            .map { ek in
                Event(id: ek.eventIdentifier ?? UUID().uuidString,
                      title: ek.title ?? String(localized: "Event"),
                      start: ek.startDate,
                      end: ek.endDate,
                      isAllDay: ek.isAllDay,
                      calendarColor: ek.calendar.color ?? .systemBlue,
                      location: ek.location)
            }
        events = Array(found)
    }

    /// "Today 3:30 PM", "Tomorrow", or a weekday for events further out.
    static func relativeTime(for event: Event) -> String {
        let calendar = Calendar.current
        if event.isAllDay {
            if calendar.isDateInToday(event.start) { return String(localized: "All day") }
            return event.start.formatted(.dateTime.weekday(.abbreviated))
        }
        let time = event.start.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(event.start) { return time }
        if calendar.isDateInTomorrow(event.start) {
            return String(localized: "Tomorrow \(time)")
        }
        let day = event.start.formatted(.dateTime.weekday(.abbreviated))
        return "\(day) \(time)"
    }
}
