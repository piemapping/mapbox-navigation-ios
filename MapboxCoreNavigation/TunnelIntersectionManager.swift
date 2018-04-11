import Foundation
import CoreLocation

public typealias RouteControllerSimulationCompletionBlock = ((_ animationEnabled: Bool, _ manager: NavigationLocationManager)-> Void)

@objc(MBTunnelIntersectionManagerDelegate)
public protocol TunnelIntersectionManagerDelegate: class {
    
    @objc(tunnelIntersectionManager:willEnableAnimationAtLocation:callback:)
    optional func tunnelIntersectionManager(_ manager: CLLocationManager, willEnableAnimationAt location: CLLocation, callback: RouteControllerSimulationCompletionBlock?)
    
    @objc(tunnelIntersectionManager:willDisableAnimationAtLocation:callback:)
    optional func tunnelIntersectionManager(_ manager: CLLocationManager, willDisableAnimationAt location: CLLocation, callback: RouteControllerSimulationCompletionBlock?)
}

@objc(MBTunnelIntersectionManager)
open class TunnelIntersectionManager: NSObject {
    
    /**
     The associated delegate for tunnel intersection manager.
     */
    @objc public weak var delegate: TunnelIntersectionManagerDelegate?
    
    /**
     The simulated location manager dedicated to tunnel simulated navigation.
     */
    @objc public var animatedLocationManager: SimulatedLocationManager?
    
    /**
     An array of bad location updates recorded upon exit of a tunnel.
     */
    @objc public var tunnelExitLocations = [CLLocation]()
    
    /**
     The flag that indicates whether simulated location manager is initialized.
     */
    @objc public var isAnimationEnabled: Bool = false
    
    /**
     Given a user's current location and route progress,
     returns a Boolean whether a tunnel has been detected on the current route step progress.
     */
    @objc public func didDetectTunnel(at routeProgress: RouteProgress) -> Bool {
        if let currentIntersection = routeProgress.currentLegProgress.currentStepProgress.currentIntersection,
           let classes = currentIntersection.outletRoadClasses {
            return classes.contains(.tunnel)
        }
        return false
    }
    
    /**
     Given a user's current location, location manager and route progress,
     returns a Boolean whether a tunnel has been detected on the current route step progress.
     */
    @objc public func didDetectTunnel(at location: CLLocation,
                                      for manager: CLLocationManager,
                                    routeProgress: RouteProgress) -> Bool {
        
        guard let currentIntersection = routeProgress.currentLegProgress.currentStepProgress.currentIntersection else {
            return false
        }
        
        if let classes = currentIntersection.outletRoadClasses {
            // Main conditions to enable simulated tunnel animation:
            // - User location is within minimum tunnel entrance radius
            // - Current intersection's road classes contain a tunnel
            //    * Animation NOT enabled OR when we receive series of bad GPS location updates
           let isWithinTunnelEntranceRadius = userWithinTunnelEntranceRadius(at: location, routeProgress: routeProgress)
            if isWithinTunnelEntranceRadius {
                return true
            } else if classes.contains(.tunnel) {
                return !isAnimationEnabled || (manager is NavigationLocationManager && !location.isQualified)
            }
        }
        
        return false
    }
    
    /**
     Given a user's current location and the route progress,
     detects whether the upcoming intersection contains a tunnel road class, and
     returns a Boolean whether they are within the minimum radius of a tunnel entrance.
     */
    @objc public func userWithinTunnelEntranceRadius(at location: CLLocation, routeProgress: RouteProgress) -> Bool {
        // Ensure the upcoming intersection is a tunnel intersection
        // OR the location speed is either at least 5 m/s or is considered a bad location update
        guard let upcomingIntersection = routeProgress.currentLegProgress.currentStepProgress.upcomingIntersection,
            let roadClasses = upcomingIntersection.outletRoadClasses, roadClasses.contains(.tunnel),
            (location.speed >= RouteControllerMinimumSpeedAtTunnelEntranceRadius || !location.isQualified) else {
                return false
        }
        
        // Distance to the upcoming tunnel entrance
        guard let distanceToTunnelEntrance = routeProgress.currentLegProgress.currentStepProgress.userDistanceToUpcomingIntersection else { return false }
        
        return distanceToTunnelEntrance < RouteControllerMinimumDistanceToTunnelEntrance
    }
    
    @objc public func enableTunnelAnimation(for manager: CLLocationManager,
                                        routeController: RouteController,
                                          routeProgress: RouteProgress,
                                       distanceTraveled: CLLocationDistance,
                                               callback: RouteControllerSimulationCompletionBlock?) {
        guard !isAnimationEnabled else { return }
        
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        DispatchQueue.main.async {
            manager.stopUpdatingHeading()
            manager.stopUpdatingLocation()
            dispatchGroup.leave()
        }
        
        dispatchGroup.notify(queue:.main) {
            self.animatedLocationManager = SimulatedLocationManager(route: routeProgress.route, distanceTraveled: distanceTraveled)
            self.animatedLocationManager?.delegate = routeController
            self.animatedLocationManager?.routeProgress = routeProgress
            
            self.animatedLocationManager?.startUpdatingLocation()
            self.animatedLocationManager?.startUpdatingLocation()
            
            if let lastKnownLocation = self.animatedLocationManager?.lastKnownLocation, lastKnownLocation.isQualified {
                routeController.rawLocation = lastKnownLocation
            }
            
            callback?(true, self.animatedLocationManager!)
        }
    }
    
    @objc public func suspendTunnelAnimation(for manager: CLLocationManager,
                                             at location: CLLocation,
                                         routeController: RouteController,
                                                callback: RouteControllerSimulationCompletionBlock?) {
        
        guard isAnimationEnabled else { return }
        
        // Disable the tunnel animation after at least 3 bad location updates.
        // Otherwise if we receive a valid location updates, disable the tunnel animation immediately.
        guard tunnelExitLocations.count > 3 || location.isQualified else {
            tunnelExitLocations.append(location)
            tunnelExitLocations = tunnelExitLocations.filter { !$0.isQualified }
            return
        }
        
        routeController.rawLocation = location
        
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        
        DispatchQueue.main.async {
            manager.stopUpdatingHeading()
            manager.stopUpdatingLocation()
            routeController.suspendLocationUpdates()
            dispatchGroup.leave()
        }
        
        dispatchGroup.notify(queue:.main) {
            routeController.resume()
            callback?(false, routeController.locationManager)
        }
    }
    
    @objc public func suspendLocationUpdates() {
        animatedLocationManager?.stopUpdatingLocation()
        animatedLocationManager?.stopUpdatingHeading()
        animatedLocationManager = nil
        tunnelExitLocations.removeAll()
    }
}
