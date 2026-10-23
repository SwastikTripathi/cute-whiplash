import OSLog

/// Failures in screenshotting and OCR land here; the punishment carries on without them (glass mode / no text).
let captureLog = Logger(subsystem: "com.lightstick.whiplash", category: "capture")
