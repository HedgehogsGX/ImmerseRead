import SwiftUI

struct ReaderSettingsView: View {
    @Binding var settings: ReaderDisplaySettings
    let supportsTypography: Bool
    var pdfReadingMode: Binding<PDFReadingMode>? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
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

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("行距")
                                Spacer()
                                Text(settings.lineHeightMultiple.formatted(.number.precision(.fractionLength(1))))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }

                            Slider(
                                value: $settings.lineHeightMultiple,
                                in: ReaderDisplaySettings.lineHeightRange,
                                step: 0.1
                            )
                                .accessibilityLabel("行距")
                                .accessibilityValue(settings.lineHeightMultiple.formatted(.number.precision(.fractionLength(1))))
                                .accessibilityIdentifier("reader.settings.lineHeight")
                        }

                        Text("阅读，让文字回到适合你的大小。")
                            .font(.system(size: settings.fontSize))
                            .lineSpacing(settings.fontSize * (settings.lineHeightMultiple - 1))
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("reader.settings.typographyPreview")

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
                    Picker("主题", selection: $settings.theme) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityLabel("阅读主题")
                    .accessibilityIdentifier("reader.settings.theme")
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
