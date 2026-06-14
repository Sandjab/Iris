import IrisAppCore
import IrisKit
import SwiftUI

/// Dense Logs row (V4): a leading colour accent encodes the event kind by position
/// (not a repeated loud pill), and the row surfaces method / status / duration —
/// fields already on `Event` but never shown. Never renders secret values
/// (`substitutedSecrets` are names; we don't display them here).
struct LogEventRow: View {
    let event: Event

    var body: some View {
        let endpoint = eventEndpoint(method: event.method, host: event.host, path: event.path)
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 3)
            Text(timeString(event.timestamp))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(event.method)
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(minWidth: 32, alignment: .leading)
            Text(endpoint.primary).font(.callout).fontWeight(.medium)
            if !endpoint.secondary.isEmpty {
                Text(endpoint.secondary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let code = event.statusCode {
                Text("\(code)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(statusColor(code))
            }
            if let ms = event.durationMs {
                Text("\(ms)ms")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var accent: Color {
        switch event.kind {
        case .substituted: return .green
        case .passThrough, .noMatch: return .gray.opacity(0.4)
        case .exfilBlocked, .systemAlert: return .red
        case .error: return .orange
        }
    }

    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<400: return .green
        case 400..<600: return .red
        default: return .secondary
        }
    }

    private func timeString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
