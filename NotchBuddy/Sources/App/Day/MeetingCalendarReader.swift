#if !APPSTORE
import EventKit
import Foundation

// MARK: - Calendar reader (EventKit)
// Reads the coming week's events off the main thread and keeps only what MeetingEvent holds:
// title, times, status and a validated meeting link. Notes are never read; nothing is written
// to the calendar, to disk or to logs.

enum CalendarAccess: Sendable, Equatable {
    case notAsked, granted, denied

    static var current: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:    return .granted
        case .notDetermined: return .notAsked
        // Restricted, refused, or write only: events can't be read.
        default:             return .denied
        }
    }
}

final class MeetingCalendarReader: @unchecked Sendable {
    private static let lookAhead: TimeInterval = 7 * 24 * 3600

    private let queue = DispatchQueue(label: "fr.louisraille.MeetingCalendarReader", qos: .utility)
    /// Used on `queue` only. Created once access is given, dropped when the feature is off.
    private var store: EKEventStore?

    /// Asks macOS for full access to the calendar: shows its prompt the first time only.
    func requestAccess(_ done: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            let asking = EKEventStore()
            store = asking
            asking.requestFullAccessToEvents { @Sendable [self] _, _ in
                // A store created before access was given sees nothing: start over.
                queue.async { [self] in
                    store = nil
                    done()
                }
            }
        }
    }

    /// The events from now to a week ahead, those running included. `done` is called off the
    /// main thread, with nil when the calendar can't be read.
    func read(now: Date, _ done: @escaping @Sendable ([MeetingEvent]?) -> Void) {
        queue.async { [self] in
            guard CalendarAccess.current == .granted else { return done(nil) }
            let store = self.store ?? EKEventStore()
            self.store = store
            let predicate = store.predicateForEvents(withStart: now,
                                                     end: now.addingTimeInterval(Self.lookAhead),
                                                     calendars: nil)
            done(store.events(matching: predicate).compactMap(Self.meeting))
        }
    }

    func close() {
        queue.async { [self] in store = nil }
    }

    private static func meeting(_ event: EKEvent) -> MeetingEvent? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        let me = event.attendees?.first(where: \.isCurrentUser)
        return MeetingEvent(
            id: event.calendarItemIdentifier,
            title: grokBotPreviewLine(event.title ?? ""),
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            isDeclined: me?.participantStatus == .declined,
            isCanceled: event.status == .canceled,
            joinURL: MeetingLink.find(url: event.url, location: event.location,
                                      structuredLocation: event.structuredLocation?.title))
    }
}
#endif
