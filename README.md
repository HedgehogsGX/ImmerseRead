# ImmersiveReader（沉浸阅读）

一个面向 iPhone 和 iPad 的本地优先电子书阅读器。文档通过系统文件选择器导入，原文件保存在应用沙盒，阅读与转换均在设备端完成。

## 当前 MVP

- iOS 17+、SwiftUI、SwiftData、Swift 6
- 本地书架、批量导入、重复内容检测、删除与启动期存储对账
- 阅读进度、分页/滚动模式、14–40 pt 字号、行距、浅色/米色/深色主题；正文底部可直接调字号
- EPUB：Readium 3.11，支持无 DRM 的可重排 EPUB
- PDF：默认提取已有文字层及文字强调色，重新换行和分页，字号变化是真实正文重排；保留 PDFKit 原版式切换
- TXT / Markdown：UTF-8，以及带 BOM 的 UTF-16；Markdown 支持常见块级与行内格式
- DOCX：内置 Mammoth，在无网络的临时 WebKit 环境中转换并清洗为可重排正文
- 旧版 `.doc`：仅使用系统 Quick Look 做兼容预览，不承诺电子书式重排

扫描 PDF OCR、账户、云同步、AI、批注、DRM 和完整 Word 版式还不在首版范围内。DOCX 首版保留标题、段落、列表、引用、代码与表格文字，主动内容、外链属性和图片会被移除。

### PDF 正文阅读

- 底部的减小/增大按钮可直接调整字号，也可在阅读设置中用滑块调整字号与行距，并实时预览
- 分页和滚动均按正文字符位置恢复阅读位置，调字号不会用整页缩放代替重排
- 读取原 PDF 的彩色文字片段，保留说话人姓名、局部词语等强调色；不根据姓名硬编码颜色，调整字号与分页不会将其清除或扩散到整段
- 浅色/米色主题保留原强调色；深色主题适度提亮过暗颜色以保持辨识。黑白灰普通正文随主题适配，避免封面白字在浅色背景上消失
- 结合实际段间距、新增缩进及“彩色短前缀 + 分隔符 + 普通对白”等线索恢复段落；同一段对白的持续缩进与普通彩色续行不会被当作新段
- 正文与原版式分别保存进度，并记住该文档上次使用的模式；旧版的 PDF 页数进度只迁移到原版式
- 使用设备端 [PDFKit 富文本提取](https://developer.apple.com/documentation/pdfkit/pdfpage/attributedstring)，不会上传文件或修改原文件；切换字号不会重新提取 PDF
- 正文模式只包含已有文字层：不恢复图片、表格版式或多栏阅读顺序，不对图片/扫描内容做 OCR。无文字页会列出提示；全扫描件可切换原版查看
- 受密码或复制权限限制的 PDF 不提取正文；保留原版式入口，但不绕过密码限制
- PDF 的分段恢复仍是基于文字层和页面几何的保守推断，不承诺任意复杂版式与原件一比一一致；需要精确布局时查看原版式

## 安全与文件限制

- 导入采用有界流式复制和 SHA-256 去重，不直接依赖外部文件的长期权限
- EPUB / DOCX 会校验文档结构、条目路径、符号链接、重复路径、数量、膨胀体积和压缩比例
- TXT / Markdown：8 MiB；DOCX：32 MiB；PDF：256 MiB；EPUB：512 MiB；旧版 DOC：128 MiB
- EPUB 解压后内容上限为 512 MiB；DOCX 转换后的 HTML 上限为 8 MiB
- PDF 正文提取最多 5,000 页、20,000 段、100,000 个颜色片段、原始提取文字最多 8 MiB；超过限制可使用原版式

## 生成与验证工程

工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成：

```sh
xcodegen generate
```

打开 `ImmersiveReader.xcodeproj`，选择 `ImmersiveReader` scheme 即可构建。依赖通过 Swift Package Manager 固定版本：Readium 3.11.0、SwiftSoup 2.13.9，以及 Readium ZIPFoundation 3.0.1。

内置的 Mammoth 浏览器构建及其许可证位于 `ImmersiveReader/Resources/Vendor/Mammoth/`。
