import Foundation
import TincanCommand

exit(Command(arguments: Array(CommandLine.arguments.dropFirst())).run())
