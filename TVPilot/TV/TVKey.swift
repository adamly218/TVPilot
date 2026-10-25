/// Samsung Smart TV remote key codes.
enum TVKey: String {
    case power = "KEY_POWER"
    case source = "KEY_SOURCE"
    case home = "KEY_HOME"
    case menu = "KEY_MENU"
    case guide = "KEY_GUIDE"
    case chList = "KEY_CH_LIST"
    case info = "KEY_INFO"
    case tools = "KEY_TOOLS"
    case back = "KEY_RETURN"
    case exit = "KEY_EXIT"

    case up = "KEY_UP"
    case down = "KEY_DOWN"
    case left = "KEY_LEFT"
    case right = "KEY_RIGHT"
    case enter = "KEY_ENTER"

    case volumeUp = "KEY_VOLUP"
    case volumeDown = "KEY_VOLDOWN"
    case mute = "KEY_MUTE"
    case channelUp = "KEY_CHUP"
    case channelDown = "KEY_CHDOWN"
    case previousChannel = "KEY_PRECH"

    case play = "KEY_PLAY"
    case pause = "KEY_PAUSE"
    case stop = "KEY_STOP"
    case rewind = "KEY_REWIND"
    case fastForward = "KEY_FF"
    case record = "KEY_REC"

    case red = "KEY_RED"
    case green = "KEY_GREEN"
    case yellow = "KEY_YELLOW"
    case blue = "KEY_CYAN"

    case n0 = "KEY_0", n1 = "KEY_1", n2 = "KEY_2", n3 = "KEY_3", n4 = "KEY_4"
    case n5 = "KEY_5", n6 = "KEY_6", n7 = "KEY_7", n8 = "KEY_8", n9 = "KEY_9"

    static func digit(_ n: Int) -> TVKey {
        [.n0, .n1, .n2, .n3, .n4, .n5, .n6, .n7, .n8, .n9][n]
    }
}
