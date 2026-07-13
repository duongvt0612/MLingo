import OSLog

public enum MLingoLogger {
    private static let subsystem = "com.duongvt.MLingo"

    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let whisper = Logger(subsystem: subsystem, category: "whisper")
    public static let translation = Logger(subsystem: subsystem, category: "translation")
    public static let overlay = Logger(subsystem: subsystem, category: "overlay")
    public static let settings = Logger(subsystem: subsystem, category: "settings")
    public static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
}
