import Foundation
import CoreGraphics

public enum WindowPlacement {
    public static func isReachable(_ frame: CGRect,on screens: [CGRect]) -> Bool {
        guard frame.width>0,frame.height>0 else { return false }
        let title = CGRect(x: frame.minX,y: frame.minY,width: frame.width,height: min(40,frame.height))
        return screens.contains { screen in
            let overlap = title.intersection(screen)
            return !overlap.isNull && overlap.width>=min(100,frame.width) && overlap.height>=min(20,frame.height)
        }
    }
    public static func fit(_ frame: CGRect,inside safe: CGRect) -> CGRect {
        let width = min(max(80,frame.width),safe.width),height = min(max(60,frame.height),safe.height)
        return CGRect(x: min(max(frame.minX,safe.minX),safe.maxX-width),
                      y: min(max(frame.minY,safe.minY),safe.maxY-height),width: width,height: height)
    }
}
