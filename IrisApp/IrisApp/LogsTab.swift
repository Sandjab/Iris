import IrisAppCore
import IrisKit
import SwiftUI

struct LogsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var snapshotEvents: [Event] = []

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            list
        }
    }

    private var filteredEvents: [Event] {
        let base = model.streamPaused ? snapshotEvents : model.events
        return base.filter { model.logFilters.matches($0) }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            TextField("Search", text: $model.logFilters.search).textFieldStyle(.roundedBorder)
            TextField("Host", text: $model.logFilters.host).textFieldStyle(.roundedBorder)
                .frame(width: 140)
            Menu {
                ForEach(Event.Kind.allCases, id: \.self) { kind in
                    Button {
                        toggleKind(kind)
                    } label: {
                        Label(
                            kind.rawValue,
                            systemImage: model.logFilters.kinds.contains(kind) ? "checkmark" : ""
                        )
                    }
                }
            } label: {
                Label("Kinds", systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 100)
            Toggle("Pause", isOn: pauseBinding).toggleStyle(.button)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var pauseBinding: Binding<Bool> {
        Binding(
            get: { model.streamPaused },
            set: { newValue in
                if newValue { snapshotEvents = model.events }
                model.streamPaused = newValue
            }
        )
    }

    private func toggleKind(_ kind: Event.Kind) {
        if model.logFilters.kinds.contains(kind) {
            model.logFilters.kinds.remove(kind)
        } else {
            model.logFilters.kinds.insert(kind)
        }
    }

    private var list: some View {
        List(filteredEvents) { event in
            EventRow(event: event)
        }
        .listStyle(.plain)
    }
}
