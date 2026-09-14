import SwiftUI

struct ReaderSettingsView: View {
    @Binding var settings: ReaderDisplaySettings
    let supportsTypography: Bool
    var pdfReadingMode: Binding<PDFReadingMode>? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if showsTypography {
                    Section {
                        preview
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                    }
                }

                if let pdfReadingMode {
                    Section {
                        Picker("PDF 内容", selection: pdfReadingMode) {
                            ForEach(PDFReadingMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("reader.settings.pdfMode")
                    } header: {
                        Text("PDF 内容")
                    } footer: {
                        Text("正文阅读保留文字强调色并重新排版，可调字号；原版式保留图片、图表和页面布局。")
                    }
                }

                Section("阅读方式") {
                    Picker("阅读方式", selection: $settings.layoutMode) {
                        ForEach(ReaderLayoutMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("reader.settings.layout")
                }

                if showsTypography {
                    Section("排版") {
                        Picker("字体", selection: $settings.fontFamily) {
                            ForEach(ReaderFontFamily.allCases) { family in
                                Text(family.title)
                                    .font(Font(family.font(ofSize: 17)))
                                    .tag(family)
                            }
                        }
                        .accessibilityIdentifier("reader.settings.fontFamily")

                        VStack(alignment: .leading, spacing: 10) {
                            ReaderFontSizeControls(
                                settings: $settings,
                                identifierPrefix: "reader.settings.fontSize.buttons"
                            )

                            Slider(
                                value: $settings.fontSize,
                                in: ReaderDisplaySettings.fontSizeRange,
                                step: 1
                            )
                                .accessibilityLabel("字号")
                                .accessibilityValue("\(Int(settings.fontSize)) 点")
                                .accessibilityIdentifier("reader.settings.fontSize")
                        }

                        sliderRow(
                            title: String(localized: "行距"),
                            value: settings.lineHeightMultiple
                                .formatted(.number.precision(.fractionLength(1))),
                            binding: $settings.lineHeightMultiple,
                            range: ReaderDisplaySettings.lineHeightRange,
                            step: 0.1,
                            identifier: "reader.settings.lineHeight"
                        )

                        sliderRow(
                            title: String(localized: "页边距"),
                            value: "\(Int(settings.margin)) 点",
                            binding: $settings.margin,
                            range: ReaderDisplaySettings.marginRange,
                            step: 4,
                            identifier: "reader.settings.margin"
                        )

                        Button("恢复默认排版") {
                            settings.resetTypography()
                        }
                    }
                } else if let pdfReadingMode {
                    Section("字号") {
                        Text("原版式显示整张 PDF 页面，不能单独改变文字大小。")
                            .foregroundStyle(.secondary)
                        Button("切换到正文阅读并调整字号") {
                            pdfReadingMode.wrappedValue = .reflow
                        }
                    }
                }

                Section("主题") {
                    themeSwatches
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .accessibilityIdentifier("reader.settings.done")
                }
            }
        }
    }

    /// A live sample in the current theme, so every control shows its effect
    /// before the sheet is dismissed.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("阅读，让文字回到适合你的大小。")
                .font(Font(settings.fontFamily.font(ofSize: settings.fontSize)))
                .lineSpacing(settings.fontSize * (settings.lineHeightMultiple - 1))
                .foregroundStyle(Color(uiColor: settings.theme.textColor))
                .accessibilityIdentifier("reader.settings.typographyPreview")

            Text("\(Int(settings.fontSize)) 点 · 行距 \(settings.lineHeightMultiple.formatted(.number.precision(.fractionLength(1)))) · 页边距 \(Int(settings.margin)) 点")
                .font(.caption)
                .foregroundStyle(Color(uiColor: settings.theme.textColor).opacity(0.55))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, max(12, settings.margin * 0.6))
        .padding(.vertical, 18)
        .background(
            settings.theme.backgroundColor,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var themeSwatches: some View {
        HStack(spacing: 12) {
            ForEach(ReaderTheme.allCases) { theme in
                Button {
                    settings.theme = theme
                } label: {
                    VStack(spacing: 7) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(theme.backgroundColor)

                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)

                            Text("文")
                                .font(.system(size: 21, weight: .medium, design: .serif))
                                .foregroundStyle(Color(uiColor: theme.textColor))
                        }
                        .frame(height: 52)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    settings.theme == theme ? Color.accentColor : .clear,
                                    lineWidth: 2.5
                                )
                                .padding(-3)
                        }

                        Text(theme.title)
                            .font(.caption2)
                            .foregroundStyle(settings.theme == theme ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.title)
                .accessibilityAddTraits(settings.theme == theme ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("阅读主题")
        .accessibilityIdentifier("reader.settings.theme")
    }

    private func sliderRow(
        title: String,
        value: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: binding, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(value)
                .accessibilityIdentifier(identifier)
        }
    }

    private var showsTypography: Bool {
        supportsTypography && pdfReadingMode?.wrappedValue != .original
    }
}

#Preview("PDF 正文设置") {
    ReaderSettingsView(
        settings: .constant(.default),
        supportsTypography: true,
        pdfReadingMode: .constant(.reflow)
    )
}

#Preview("纯文本设置") {
    ReaderSettingsView(
        settings: .constant(.default),
        supportsTypography: true
    )
}
