import AppKit
import SwiftUI

/// Состояние значка в меню-баре (E4.2, дизайн значков ai-recorder-icons.md в документах проекта).
enum MenuBarIconState: Equatable {
    case idle, recording, paused, processing, error

    /// Приоритет из дизайна: Запись / Пауза → Обработка → Ошибка → Ожидание (запись во время
    /// обработки, ADR-004 решение 42). `.starting` и `.stopping` показываются как запись.
    /// `showsFailure`: последняя обработка упала не из-за отмены, и ошибку ещё не сбросили
    /// новая запись или новый запуск обработки (флаг ведёт RecorderController).
    static func resolve(phase: RecorderController.Phase,
                        transcription: RecorderController.Transcription,
                        showsFailure: Bool) -> MenuBarIconState {
        switch phase {
        case .paused: return .paused
        case .starting, .recording, .stopping: return .recording
        case .idle: break
        }
        switch transcription {
        case .running, .diarizing: return .processing
        case .failed where showsFailure: return .error
        default: return .idle
        }
    }

    /// Кадров анимации; анимируется только «Обработка».
    var frameCount: Int { self == .processing ? 2 : 1 }
}

/// Глифы из app/Resources/Icons/MenuBar, которые build-app.sh кладёт в Contents/Resources/MenuBar.
/// Без .app (swift run) файлов нет: значок рисуется прежними SF Symbols.
@MainActor
enum MenuBarIcons {
    static let size = NSSize(width: 18, height: 18)
    private static var cache: [String: NSImage] = [:]

    static func image(_ state: MenuBarIconState, frame: Int) -> NSImage? {
        let name: String
        switch state {
        case .idle: name = "menubar-idle"
        case .recording: name = "menubar-recording"
        case .paused: name = "menubar-paused"
        case .processing: name = frame % 2 == 0 ? "menubar-processing-1" : "menubar-processing-2"
        case .error: name = "menubar-error"
        }
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf", subdirectory: "MenuBar")
                ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "MenuBar"),
              let source = NSImage(contentsOf: url) else { return nil }
        source.size = size
        let image: NSImage
        if state == .recording {
            guard let composite = RecordingGlyph(source: source)?.image else { return nil }
            image = composite
        } else {
            source.isTemplate = true   // macOS перекрашивает под светлый и тёмный меню-бар
            image = source
        }
        cache[name] = image
        return image
    }

    /// Прежние значки (до E4.2), когда глифов в бандле нет.
    static func symbolName(_ state: MenuBarIconState) -> String {
        switch state {
        case .paused: return "pause.circle.fill"
        case .recording: return "record.circle.fill"
        default: return "waveform.circle"
        }
    }
}

/// «Запись»: волна ведёт себя как template, красная точка остаётся красной. Template-изображение
/// обесцветило бы точку, поэтому глиф делится по цвету пикселей на маску волны и точку
/// (геометрия только из файла), а drawingHandler при каждой отрисовке заливает маску цветом
/// текста под текущий вид меню-бара и рисует точку поверх.
@MainActor
final class RecordingGlyph {
    private let source: NSImage
    private var layers: [Int: (wave: CGImage, dot: CGImage)] = [:]

    init?(source: NSImage) {
        self.source = source
        guard layers(scale: 2) != nil else { return nil }
    }

    var image: NSImage {
        let image = NSImage(size: MenuBarIcons.size, flipped: false) { [self] rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // масштаб устройства: 1x или 2x (3x на всякий случай)
            let device = ctx.convertToDeviceSpace(CGSize(width: rect.width, height: rect.height))
            let scale = min(3, max(1, Int((abs(device.width) / rect.width).rounded(.up))))
            guard let layers = MainActor.assumeIsolated({ self.layers(scale: scale) }) else { return false }
            ctx.saveGState()
            ctx.clip(to: rect, mask: layers.wave)
            NSColor.labelColor.setFill()   // разрешается по appearance кнопки меню-бара
            rect.fill()
            ctx.restoreGState()
            ctx.draw(layers.dot, in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Маска волны (DeviceGray без альфы, как требует clip(to:mask:): белое = непрозрачно) и точка в исходном цвете для масштаба.
    private func layers(scale: Int) -> (wave: CGImage, dot: CGImage)? {
        if let cached = layers[scale] { return cached }
        let width = Int(MenuBarIcons.size.width) * scale, height = Int(MenuBarIcons.size.height) * scale
        guard let rgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // PDF рисуется вектором сразу в нужном масштабе
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        source.draw(in: NSRect(origin: .zero, size: MenuBarIcons.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var mask = [UInt8](repeating: 0, count: width * height)
        var dot = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2]), a = Int(pixels[i * 4 + 3])
            guard a > 0 else { continue }
            // красная точка #FF3B30: красный заметно больше зелёного и синего (значения premultiplied)
            if r - max(g, b) > a / 4 {
                for c in 0..<4 { dot[i * 4 + c] = pixels[i * 4 + c] }
            } else {
                mask[i] = UInt8(a)
            }
        }
        guard let wave = Self.image(&mask, width: width, height: height, components: 1, space: CGColorSpaceCreateDeviceGray(),
                                    info: CGImageAlphaInfo.none.rawValue),
              let red = Self.image(&dot, width: width, height: height, components: 4, space: rgb,
                                   info: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        layers[scale] = (wave, red)
        return (wave, red)
    }

    private static func image(_ bytes: inout [UInt8], width: Int, height: Int, components: Int,
                              space: CGColorSpace, info: UInt32) -> CGImage? {
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * components, space: space, bitmapInfo: info)?.makeImage()
        }
    }
}

/// Значок в меню-баре: глиф из бандла или SF Symbol без .app.
struct MenuBarLabel: View {
    let state: MenuBarIconState
    let frame: Int

    var body: some View {
        if let image = MenuBarIcons.image(state, frame: frame) {
            Image(nsImage: image)
        } else {
            Image(systemName: MenuBarIcons.symbolName(state))
        }
    }
}
