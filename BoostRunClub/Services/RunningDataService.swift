//
//  RunningDataService.swift
//  BoostRunClub
//
//  Created by 조기현 on 2020/12/01.
//

import Combine
import CoreLocation
import Foundation

protocol RunningDataServiceable {
    var runningTime: CurrentValueSubject<TimeInterval, Never> { get }
    var distance: CurrentValueSubject<Double, Never> { get }
    var pace: CurrentValueSubject<Int, Never> { get }
    var avgPace: CurrentValueSubject<Int, Never> { get }
    var isRunning: Bool { get }
    var currentLocation: PassthroughSubject<CLLocationCoordinate2D, Never> { get }
    var locations: [CLLocation] { get }
    var runningSplits: [RunningSplit] { get }
    var currentRunningSlice: RunningSlice
    func start()
    func stop()
    func pause()
    func resume()
}

class RunningDataService: RunningDataServiceable {
    var locationProvider: LocationProvidable

    var cancellables = Set<AnyCancellable>()
    var locations = [CLLocation]()

    var startTime: TimeInterval = 0
    var endTime: TimeInterval = 0
    var lastUpdatedTime: TimeInterval = 0

    var currentLocation = PassthroughSubject<CLLocationCoordinate2D, Never>()
    var runningTime = CurrentValueSubject<TimeInterval, Never>(0)
    var pace = CurrentValueSubject<Int, Never>(0)
    var avgPace = CurrentValueSubject<Int, Never>(0)
    var distance = CurrentValueSubject<Double, Never>(0)

    var runningSplits = [RunningSplit]()
    var currentRunningSplit = RunningSplit()
    var currentRunningSlice = RunningSlice()

    private(set) var isRunning: Bool = false
    let eventTimer: EventTimerProtocol

    init(eventTimer: EventTimerProtocol = EventTimer(), locationProvider: LocationProvidable) {
        self.eventTimer = eventTimer
        self.locationProvider = locationProvider
        locationProvider.locationSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                guard let self = self else { return }
                self.updateLocation(location: location)
                self.updateTime(currentTime: location.timestamp.timeIntervalSinceReferenceDate)
            }
            .store(in: &cancellables)

        eventTimer.timeSubject
            .sink { [weak self] time in
                self?.updateTime(currentTime: time)
            }
            .store(in: &cancellables)
    }

    func initializeRunningData() {
        startTime = Date.timeIntervalSinceReferenceDate
        endTime = 0
        lastUpdatedTime = startTime
        runningTime.value = 0
        pace.value = 0
        avgPace.value = 0
        distance.value = 0
        locations.removeAll()
    }

    func start() {
        if !isRunning {
            isRunning = true
            eventTimer.start()
            locationProvider.startBackgroundTask()
            initializeRunningData()
        }
        
    }

    func stop() {
        locationProvider.stopBackgroundTask()
        eventTimer.stop()
        isRunning = false
    }

    func pause() {
        isRunning = false
    }

    func resume() {
        isRunning = true
    }

    func addSlice() {
        currentRunningSlice.endIndex = locations.count - 1
        currentRunningSplit.runningSlices.append(currentRunningSlice)
        currentRunningSlice = RunningSlice()
        currentRunningSlice.startIndex = locations.count - 1
    }

    func addSplit() {
        currentRunningSlice.endIndex = locations.count - 1
    }

    func updateTime(currentTime: TimeInterval) {
        if isRunning {
            runningTime.value += currentTime - lastUpdatedTime
        }
        lastUpdatedTime = currentTime
    }

    func updateLocation(location: CLLocation) {
        currentLocation.send(location.coordinate)

        if isRunning {}

//        if let prevLocation = locations.last {
//            distance.value += location.distance(from: prevLocation)
//        }
//
//        let paceDouble = 1000 / location.speed
//        if !(paceDouble.isNaN || paceDouble.isInfinite) {
//            pace.value = Int(paceDouble)
//        }
//
//        locations.append(location)
//        avgPace.value = (avgPace.value * (locations.count - 1) + pace.value) / locations.count
    }
}

// struct RunningSlice {
//    var startIndex: Int
//    var endIndex: Int
//    var distance: Double
// }
