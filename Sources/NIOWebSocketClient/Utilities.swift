internal extension FixedWidthInteger {
    static var random: Self {
        return self.random(in: Self.min...Self.max)
    }
}
