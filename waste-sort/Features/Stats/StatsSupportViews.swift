import Charts
import SwiftUI

struct DailyXDomainModifier: ViewModifier {
    let domain: ClosedRange<Date>?

    func body(content: Content) -> some View {
        if let domain {
            content.chartXScale(domain: domain)
        } else {
            content
        }
    }
}

struct SiteNameEditorSheet: View {
    @Binding var siteNameDraft: String
    var onCancel: () -> Void
    var onSave: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Shown in the Waste Stats title.")
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundStyle(.secondary)

                TextField("Site name", text: $siteNameDraft)
                    .font(.system(size: 20, weight: .regular, design: .default))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(white: 0.94), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .focused($fieldFocused)

                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Site name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { fieldFocused = true }
        }
    }
}
