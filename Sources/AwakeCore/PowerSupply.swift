public enum PowerSupply: Equatable, Sendable {
    case externalPower, battery, unknown

    public func permitsAwake(allowBattery: Bool) -> Bool {
        switch self {
        case .externalPower: true
        case .battery: allowBattery
        case .unknown: false
        }
    }
}
