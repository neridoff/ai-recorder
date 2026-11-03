// swift-tools-version:5.9
import PackageDescription
import Foundation

// Готовые dylib sherpa-onnx (ADR-004 решение 23), скачивает scripts/fetch-sherpa-onnx.sh.
let sherpaLib = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Vendor/sherpa-onnx/lib").path

let package = Package(
    name: "AIRecorder",
    platforms: [.macOS("13.3")],   // 13.3: минимальная версия whisper.xcframework
    products: [
        .executable(name: "AIRecorder", targets: ["AIRecorder"]),
        .executable(name: "verify-session", targets: ["verify-session"]),
        .executable(name: "mix-session", targets: ["mix-session"]),
        .executable(name: "transcribe-session", targets: ["transcribe-session"]),
        .executable(name: "diarize-session", targets: ["diarize-session"]),
        .library(name: "RecorderCore", targets: ["RecorderCore"]),
    ],
    targets: [
        // Захват, запись дорожек, метаданные и восстановление сессий. Без UI.
        .target(name: "RecorderCore"),
        // Приложение в меню-баре. Info.plist встраивается в бинарник, чтобы запрос
        // на микрофон работал и при запуске без .app (swift run).
        .executableTarget(
            name: "AIRecorder",
            dependencies: ["RecorderCore", "WhisperEngine", "SherpaEngine"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist",
                              "-Xlinker", "Resources/Info.plist"])
            ]
        ),
        // CLI проверки сессии: открывает файлы через AVAudioFile и сверяет с session.json.
        .executableTarget(name: "verify-session", dependencies: ["RecorderCore"]),
        // CLI сведения (E2): выравнивает дорожки, пишет mixed.m4a и alignment в session.json.
        .executableTarget(name: "mix-session", dependencies: ["RecorderCore"]),
        // whisper.cpp (E3, ADR-004 решение 11): готовый xcframework, версия закреплена.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"),
        // Обёртка над C API whisper.cpp: реализует TranscriptionEngine из RecorderCore.
        .target(name: "WhisperEngine", dependencies: ["RecorderCore", "whisper"]),
        // C API sherpa-onnx (E4): заголовок и dylib в Vendor/sherpa-onnx.
        .systemLibrary(name: "CSherpaOnnx"),
        // Разметка говорящих на sherpa-onnx: реализует SpeakerDiarizer из RecorderCore.
        // rpath: рядом с бинарником (CLI в build/), Frameworks в .app и Vendor для swift run.
        .target(
            name: "SherpaEngine",
            dependencies: ["RecorderCore", "CSherpaOnnx"],
            linkerSettings: [
                .unsafeFlags(["-L", sherpaLib,
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", sherpaLib])
            ]),
        // CLI расшифровки (E3) и разметки (E4): transcript.json и статус в session.json.
        .executableTarget(name: "transcribe-session", dependencies: ["RecorderCore", "WhisperEngine", "SherpaEngine"]),
        // CLI только разметки (E4): повтор с другим порогом и сверка с Labels.txt.
        .executableTarget(name: "diarize-session", dependencies: ["RecorderCore", "SherpaEngine"]),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"]),
        // Состояние значка меню-бара (E4.2): чистая функция из исполняемого таргета.
        .testTarget(name: "AIRecorderTests", dependencies: ["AIRecorder"]),
    ]
)
