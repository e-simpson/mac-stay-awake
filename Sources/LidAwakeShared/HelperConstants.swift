public enum HelperConstants {
    public static let appBundleIdentifier = "dev.personal.MacStayAwake"
    public static let helperIdentifier = "dev.personal.MacStayAwake.helper"
    public static let machServiceName = helperIdentifier
    public static let plistName = "\(helperIdentifier).plist"
    // Replace with your own 10-character Apple Developer Team ID before signing.
    public static let teamIdentifier = "UNCONFIGURED"
    public static let protocolVersion = 17

    // The packaging script evaluates these same requirements before accepting a build.
    public static let appRequirement = "anchor apple generic and identifier \"\(appBundleIdentifier)\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    public static let helperRequirement = "anchor apple generic and identifier \"\(helperIdentifier)\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
}
