import SwiftUI

/// What everything in the app does, and the logic behind it.
struct HelpView: View {
    @State private var query = ""

    private var results: [HelpTopic] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return HelpTopic.all.filter { $0.matches(trimmed) }
    }

    var body: some View {
        List {
            if query.isEmpty {
                ForEach(HelpTopic.Chapter.allCases) { chapter in
                    let topics = HelpTopic.all.filter { $0.chapter == chapter }
                    if !topics.isEmpty {
                        Section(chapter.label) {
                            ForEach(topics) { topic in
                                link(to: topic)
                            }
                        }
                    }
                }
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                Section("\(results.count) of \(HelpTopic.all.count)") {
                    ForEach(results) { topic in
                        link(to: topic)
                    }
                }
            }
        }
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search help"
        )
        .withoutBottomScrollEdgeBlur()
    }

    private func link(to topic: HelpTopic) -> some View {
        NavigationLink {
            HelpTopicView(topic: topic)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title)
                Text(topic.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

/// One explanation.
struct HelpTopicView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(topic.summary)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                ForEach(Array(topic.body.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
        .withoutBottomScrollEdgeBlur()
    }
}
