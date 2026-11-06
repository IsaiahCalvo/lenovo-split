import Foundation

/// Physical output names are stored in transport-half order. Virtual panel
/// numbers can move between outputs without renaming the physical monitors.
public struct PanelAssignment: Equatable, Sendable {
    public var outputNames: [String]
    public init(outputNames: [String]) {
        self.outputNames = outputNames.count == 2 ? outputNames : ["Display 1", "Display 2"]
    }
    public func panelNames(swapped: Bool) -> [String] {
        swapped ? Array(outputNames.reversed()) : outputNames
    }
    public static func fromPanelNames(_ names: [String],swapped: Bool) -> Self {
        Self(outputNames: swapped ? Array(names.reversed()) : names)
    }
}
