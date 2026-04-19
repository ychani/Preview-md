import Foundation

@_silgen_name("NSExtensionMain")
private func NSExtensionMain(_ argc: Int32,
                             _ argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>) -> Int32

exit(NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv))
