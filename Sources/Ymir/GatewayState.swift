enum GatewayState {
    case stopped
    case starting
    case running

    init(isRunning: Bool, shouldBeRunning: Bool, isRestarting: Bool) {
        if isRestarting {
            self = .starting
        } else if isRunning {
            self = .running
        } else {
            self = shouldBeRunning ? .starting : .stopped
        }
    }

    var menuTitle: String {
        switch self {
        case .stopped: return "Gateway: Stopped"
        case .starting: return "Gateway: Starting…"
        case .running: return "Gateway: Running on :4141"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .stopped: return "Ymir — gateway stopped"
        case .starting: return "Ymir — gateway starting"
        case .running: return "Ymir — gateway running"
        }
    }
}
