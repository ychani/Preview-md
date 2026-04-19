import SwiftUI

/// One heading in the Table of Contents. `id` is the DOM element id used to
/// scroll the preview WebView to the heading.
struct TOCEntry: Identifiable, Hashable {
    let level: Int
    let text: String
    let id: String
}

/// A uniquely-identified request to scroll the preview to a given heading.
/// The UUID lets the preview coordinator detect re-issued scroll requests for
/// the same heading (two taps in a row) and replay them.
struct ScrollRequest: Equatable {
    let id: UUID
    let headingID: String
}

struct TOCView: View {
    let entries: [TOCEntry]
    var onSelect: (TOCEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Contents")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if entries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.indent")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No headings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List(entries) { entry in
                    Button {
                        onSelect(entry)
                    } label: {
                        HStack(spacing: 0) {
                            Text(entry.text)
                                .font(fontFor(level: entry.level))
                                .foregroundStyle(entry.level == 1 ? .primary : .secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, CGFloat(max(0, entry.level - 1)) * 12)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func fontFor(level: Int) -> Font {
        switch level {
        case 1: return .callout.weight(.semibold)
        case 2: return .callout
        default: return .caption
        }
    }
}
