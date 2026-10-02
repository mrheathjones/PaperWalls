import AppKit
import SwiftUI
import os

// Searchable pickers for the Scene Composer (spec §10): any installed
// font family, and the full SF Symbols catalog.

// MARK: - Font picker

/// Shows the current font and opens a searchable list of the system font
/// styles plus every installed family (what Font Book lists).
struct FontFamilyPicker: View {
    @Binding var font: SceneFont

    @State private var isPresented = false
    @State private var query = ""

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Text(currentName)
                    .font(font.font(size: 14))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Font: \(currentName)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            pickerBody
        }
    }

    /// A chosen family that isn't installed here still shows by name, so
    /// it's clear why the preview is using the system font.
    private var currentName: String {
        if let family = font.family {
            return SceneFontLibrary.isInstalled(family) ? family : "\(family) (not installed)"
        }
        return "System \(font.design.displayName)"
    }

    private var pickerBody: some View {
        VStack(spacing: 0) {
            PickerSearchField(prompt: "Search fonts", text: $query)
                .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !systemDesigns.isEmpty {
                        sectionLabel("System")
                        ForEach(systemDesigns) { design in
                            row(title: "System \(design.displayName)",
                                font: .system(size: 15, design: design.fontDesign),
                                isSelected: font.family == nil && font.design == design) {
                                font.family = nil
                                font.design = design
                            }
                        }
                    }
                    if !families.isEmpty {
                        sectionLabel("Installed Fonts")
                        ForEach(families, id: \.self) { family in
                            row(title: family,
                                font: .custom(family, fixedSize: 15),
                                isSelected: font.family == family) {
                                font.family = family
                            }
                        }
                    }
                    if systemDesigns.isEmpty && families.isEmpty {
                        Text("No fonts match “\(query)”.")
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .padding(14)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: 300, height: 380)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var systemDesigns: [SceneFont.Design] {
        SceneFont.Design.allCases.filter {
            trimmedQuery.isEmpty || "System \($0.displayName)".localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var families: [String] {
        guard !trimmedQuery.isEmpty else { return SceneFontLibrary.families }
        return SceneFontLibrary.families.filter { $0.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.sectionLabel)
            .tracking(1.2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func row(title: String, font rowFont: Font, isSelected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button {
            action()
            isPresented = false
        } label: {
            HStack {
                Text(title)
                    .font(rowFont)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - SF Symbols

/// Every SF Symbol name this macOS knows, with search keywords.
///
/// macOS has no public API for listing symbols, so this reads the system's
/// own catalog (the same files the SF Symbols app uses). If a future
/// macOS moves them, the catalog is simply empty and the composer falls
/// back to its built-in shortlist — nothing breaks.
enum SFSymbolCatalog {
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "symbols")

    private static let resourcesPath =
        "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources"

    struct Entry: Identifiable {
        let name: String
        /// Lowercased name + keywords, for matching.
        let searchText: String
        var id: String { name }
    }

    static let entries: [Entry] = load()

    private static func load() -> [Entry] {
        let orderURL = URL(fileURLWithPath: "\(resourcesPath)/symbol_order.plist")
        guard let data = try? Data(contentsOf: orderURL),
              let names = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] else {
            log.info("System symbol catalog not found; using the built-in shortlist")
            return []
        }
        var keywords: [String: [String]] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "\(resourcesPath)/symbol_search.plist")),
           let parsed = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: [String]] {
            keywords = parsed
        }
        return names.map { name in
            Entry(name: name,
                  searchText: ([name.replacingOccurrences(of: ".", with: " ")] + (keywords[name] ?? []))
                      .joined(separator: " ").lowercased())
        }
    }

    /// Symbols whose name or keywords contain every word of the query.
    static func search(_ query: String) -> [Entry] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "." }).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            words.allSatisfy { entry.searchText.contains($0) }
        }
    }
}

/// "Browse All Symbols…" — a searchable grid of the whole catalog.
struct SymbolBrowserButton: View {
    @Binding var symbolName: String

    @State private var isPresented = false
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 6)]

    var body: some View {
        Button("Browse All Symbols…") {
            isPresented = true
        }
        .disabled(SFSymbolCatalog.entries.isEmpty)
        .help(SFSymbolCatalog.entries.isEmpty
              ? "The full symbol list isn't available on this version of macOS"
              : "Choose from all \(SFSymbolCatalog.entries.count) SF Symbols")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            browser
        }
    }

    private var browser: some View {
        let results = SFSymbolCatalog.search(query)
        return VStack(spacing: 0) {
            PickerSearchField(prompt: "Search \(SFSymbolCatalog.entries.count) symbols", text: $query)
                .padding(10)
            Divider()
            if results.isEmpty {
                Text("No symbols match “\(query)”.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(results) { entry in
                            symbolButton(entry.name)
                        }
                    }
                    .padding(10)
                }
            }
            Divider()
            Text(symbolName)
                .font(Theme.pathMono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 420, height: 440)
    }

    private func symbolButton(_ name: String) -> some View {
        let isSelected = symbolName == name
        return Button {
            symbolName = name
        } label: {
            Image(systemName: name)
                .font(.system(size: 18))
                .frame(width: 44, height: 40)
                .foregroundStyle(isSelected ? .white : .primary)
                .background(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.chipFill),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Shared search field

struct PickerSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("", text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(Theme.body)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
